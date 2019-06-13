#' @import shiny
#' @import shinyWidgets
#' @import miniUI
#' @import rstudioapi
#' @import leaflet
#' @import dplyr
#' @import CDECRetrieve
#' @export

CDECRetrieveGadget <- function() {

  counties <- c("Alameda", "Alpine", "Amador", "Butte", "Calaveras", "Colusa",
                "Contra Costa", "Del Norte", "El Dorado", "Fresno", "Glenn",
                "Humboldt", "Imperial", "Inyo", "Kern", "Kings", "Lake", "Lassen",
                "Los Angeles", "Madera", "Marin", "Mariposa", "Mendocino", "Merced",
                "Modoc", "Mono", "Monterey", "Napa", "Nevada", "Orange", "Placer",
                "Plumas", "Riverside", "Sacramento", "San Benito", "San Bernardino",
                "San Diego", "San Francisco", "San Joaquin", "San Luis Obispo",
                "San Mateo", "Santa Barbara", "Santa Clara", "Santa Cruz", "Shasta",
                "Sierra", "Siskiyou", "Solano", "Sonoma", "Stanislaus", "Sutter",
                "Tehama", "Trinity", "Tulare", "Tuolumne", "Ventura", "Yolo",
                "Yuba")

  ui <- miniPage(
    gadgetTitleBar("CDECRetrieveGUI"),
    miniTabstripPanel(
      miniTabPanel("Select Station", icon = icon("map-marked-alt"),
                   miniContentPanel(padding = 0,
                                    leafletOutput("map", height = "100%"),
                                    absolutePanel(
                                      top = 10, right = 20,
                                      pickerInput(inputId = "county", label = "Select county", width = "175px",
                                                  choices = counties, selected = "Sacramento",
                                                  options = list(`live-search` = TRUE)
                                      )
                                    )
                   )
      ),
      miniTabPanel("Build Query", icon = icon("wrench"),
                   miniContentPanel(
                     DT::DTOutput("stationDataSubTable"),
                     DT::DTOutput("sensorDataTable"),
                     br(),
                     fluidRow(
                       column(width = 8,
                              br(),
                              verbatimTextOutput("queryText")),
                       column(width = 4,
                              dateRangeInput("date_range", "Date range"),
                              actionButton("send_code", "Insert code in script"))
                     )
                   )
      )
    )
  )

  server <- function(input, output, session) {

    rv <- reactiveValues(selected_station = "FPT", query = NULL)

    output$map <- renderLeaflet({
      leaflet() %>%
        addProviderTiles("Esri.WorldTopoMap", group = "ESRI World Topo Map") %>%
        setView(lng = -121.5, lat = 38.6, zoom = 9)
    })

    proxyMap = leafletProxy("map")

    stationData <- reactive({
      # midpoint of lat/lng coords from http://www.geomidpoint.com/calculation.html
      # calculation starts in this reactive and finishes in observeEvent when selected county changes
      cdec_stations(county = toupper(input$county)) %>%
        filter(!(station_id %in% c("tst", "ttt")), # test stations with weird lat/lon coords
               longitude > -999.9990,              # coords used to indicate missing values (apparently)
               latitude < 99.99900) %>%
        mutate(lat_rads = latitude * pi/180,
               lng_rads = longitude * pi/180,
               X = cos(lat_rads) * cos(lng_rads),
               Y = cos(lat_rads) * sin(lng_rads),
               Z = sin(lat_rads),
               station_id = toupper(station_id))
    })

    stationDataSub <- reactive({
      d <- stationData() %>%
        mutate(latlong = paste0(latitude, longitude))
      ll = d$latlong[d$station_id == rv$selected_station]  # some stations have the same coordinates
      d %>% filter(latlong %in% ll) %>% select(-latlong)
    })

    output$stationDataSubTable = DT::renderDT(
      select(stationDataSub(), station_id, name, river_basin, county, elevation, operator),
      selection = "none", style = "bootstrap", rownames = FALSE,
      options = list(bLengthChange = FALSE, bPaginate = FALSE, searching = FALSE))

    # update the map markers and view  when selected counted changes
    observeEvent(input$county, {
      req(stationData())              # seems to stop warnings about Unknown or uninitialised columns
      station_data <- stationData()
      x = mean(station_data$X, na.rm = TRUE)
      y = mean(station_data$Y, na.rm = TRUE)
      z = mean(station_data$Z, na.rm = TRUE)
      hyp = sqrt(x^2 + y^2)

      # 9 is default zoom level; not sure why this extra hoop was needed
      mz = ifelse(is.null(input$map_zoom), 9, input$map_zoom)
      proxyMap %>%
        clearMarkers() %>%
        setView(lng = atan2(y, x) * 180/pi,
                lat = atan2(z, hyp) * 180/pi,
                zoom = mz) %>%
        addCircleMarkers(data = station_data, lng = ~longitude, lat = ~latitude,
                         popup = ~station_id, layerId = ~station_id)
    })

    observeEvent(input$map_marker_click, {
      # SelectedStation is used to indicate that the user has clicked on a feature that is currently selected
      # app responds by setting dropdown menu to empty which triggers removal of the selected marker
      # if the user clicks on an unselected station, then the station ID is returned as the layer id (i.e., p$id)
      p <- input$map_marker_click
      req(p$id)
      if (p$id ==  "SelectedStation") {
        rv$selected_station = NULL
        proxyMap %>% removeMarker(layerId = p$id)
      } else {
        rv$selected_station = p$id
        proxyMap %>%
          setView(lng = p$lng, lat = p$lat, input$map_zoom) %>%
          # add selected marker
          addCircleMarkers(data = filter(stationData(), station_id == p$id),
                           lat = ~latitude, lng = ~longitude,
                           color = "#FDE725FF", opacity = 0.8,
                           fillColor = "yellow", fillOpacity = 0.5,
                           layerId = "SelectedStation"
          )
      }
    })

    sensorData <- reactive({
      # some stations have identical lat/lng and can't be selected separately from the map
      stations = unique(stationDataSub()$station_id)
      out = list()
      for (i in stations){
        out[[i]] = cdec_datasets(i)
      }
      bind_rows(out, .id = "station_id")
    })

    output$sensorDataTable = DT::renderDT(
      sensorData(), selection = "single", style = "bootstrap", rownames = FALSE,
      options = list(pageLength = 4, bLengthChange = FALSE, bPaginate = TRUE, searching = FALSE))

    observe({
      # can't use observeEvent because unselecting a row won't allow for resetting of date range picker
      s <- input$sensorDataTable_rows_selected
      if (!is.null(s)){
        d <- sensorData()[s,]
        updateDateRangeInput(session, "date_range", start = d$start, end = d$end, min = d$start, max = d$end)
      }else{
        # reset date range picker
        updateDateRangeInput(session, "date_range", start = NA, end = NA, min = NA, max = NA)
      }
    })

    observe({
      # can't combine with the date range observer because query depends on date range
      s <- input$sensorDataTable_rows_selected
      if (!is.null(s)){
        d <- sensorData()[s,]
        rv$query = paste0("cdec_query(station = \"", d$station_id, "\", sensor_num = ",
                          d$sensor_number, ", dur_code = \"", d$duration,
                          "\",\n           start_date = \"", input$date_range[1], "\", end_date = \"",
                          input$date_range[2], "\")")
      }else{
        rv$query = "Not a valid query.\nSelect a station from the map and a row from the sensor table."
      }
    })

    output$queryText <- renderText({
      rv$query
    })

    observeEvent(input$send_code,{
      rstudioapi::insertText(rv$query)
    })

    # When the Done button is clicked, stop app (without returning any value)
    observeEvent(input$done, {
      stopApp()
    })
  }

  runGadget(ui, server, viewer = dialogViewer(dialogName = "CDECRetrieveGadget",
                                              width = 900, height = 650))
}


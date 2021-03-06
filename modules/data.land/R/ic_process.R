##' @name ic_process
##' @title ic_process
##' @export
##'
##' @param settings pecan settings list
##' @param dbfiles where to write files
##' @param overwrite whether to force ic_process to proceed
##' @author Istem Fer
ic_process <- function(settings, input, dir, overwrite = FALSE){
  
  
  #--------------------------------------------------------------------------------------------------#
  # Extract info from settings and setup
  site       <- settings$run$site
  start_date <- settings$run$start.date
  end_date   <- settings$run$end.date
  model      <- settings$model$type
  host       <- settings$host
  dbparms    <- settings$database
  
  
  # If overwrite is a plain boolean, fill in defaults for each module
  if (!is.list(overwrite)) {
    if (overwrite) {
      overwrite <- list(getveg = TRUE,  putveg = TRUE)
    } else {
      overwrite <- list(getveg = FALSE, putveg = FALSE)
    }
  } else {
    if (is.null(overwrite$getveg)) {
      overwrite$getveg <- FALSE
    }
    if (is.null(overwrite$putveg)) {
      overwrite$putveg <- FALSE
    }
  }
  
  # set up bety connection
  bety <- dplyr::src_postgres(dbname   = dbparms$bety$dbname, 
                              host     = dbparms$bety$host, 
                              user     = dbparms$bety$user, 
                              password = dbparms$bety$password)
  
  con <- bety$con
  on.exit(db.close(con))
  
  # set up host information
  machine.host <- ifelse(host == "localhost" || host$name == "localhost", fqdn(), host$name)
  machine <- db.query(paste0("SELECT * from machines where hostname = '", machine.host, "'"), con)
  
  # retrieve model type info
  if(is.null(model)){
    modeltype_id <- db.query(paste0("SELECT modeltype_id FROM models where id = '", settings$model$id, "'"), con)[[1]]
    model <- db.query(paste0("SELECT name FROM modeltypes where id = '", modeltype_id, "'"), con)[[1]]
  }
  
  # setup site database number, lat, lon and name and copy for format.vars if new input
  new.site <- data.frame(id = as.numeric(site$id), 
                         lat = PEcAn.data.atmosphere::db.site.lat.lon(site$id, con = con)$lat, 
                         lon = PEcAn.data.atmosphere::db.site.lat.lon(site$id, con = con)$lon)
  str_ns <- paste0(new.site$id %/% 1e+09, "-", new.site$id %% 1e+09)
  
  outfolder <- file.path(dir, paste0(input$source, "_site_", str_ns))

  # veg or some other IC? Need to update later for other models
  vegIC <- c("css", "pss", "site")
  getveg.id <- putveg.id <- NULL
  
  #--------------------------------------------------------------------------------------------------#
  # Checks 
  
  ic_check <- ic_status_check(getveg.id, putveg.id, input, site_id = new.site$id, model, start_date, con)

  getveg.id <- ic_check$getveg.id 
  putveg.id <- ic_check$putveg.id 
  
  #--------------------------------------------------------------------------------------------------#
  # Load/extract + match species module
  
  if (is.null(getveg.id) & is.null(putveg.id) & input$output %in% vegIC) {

    getveg.id <- .get.veg.module(input_veg = input, 
                              outfolder = outfolder, 
                              start_date = start_date, end_date = end_date,
                              dbparms = dbparms,
                              lat = new.site$lat, lon = new.site$lon, site_id = new.site$id,
                              host = host, overwrite = overwrite$getveg)

  }
  

  #--------------------------------------------------------------------------------------------------#
  # Match species to PFTs + veg2model module
  
  if (!is.null(getveg.id) & is.null(putveg.id) & input$output %in% vegIC) { # probably need a more sophisticated check here
    
    putveg.id <- .put.veg.module(getveg.id = getveg.id, bety = bety, 
                                input_veg = input, pfts = settings$pfts,
                                outfolder = outfolder, 
                                dir = dir, machine = machine, model = model,
                                start_date = start_date, end_date = end_date,
                                lat = new.site$lat, lon = new.site$lon, site_id = new.site$id,
                                host = host, overwrite = overwrite$putveg)
    
  }

  #--------------------------------------------------------------------------------------------------#
  # Fill settings
  if (!is.null(putveg.id) & input$output %in% vegIC) {
    
    model_file <- db.query(paste("SELECT * from dbfiles where container_id =", putveg.id), con)
    
    # now that we don't have multipasses, convert.input only inserts 1st filename
    # do we want to change it in convert.inputs such that it loops over the dbfile.insert?
    path_to_settings <- file.path(model_file[["file_path"]], model_file[["file_name"]])
    settings$run$inputs[[input$output]][['path']] <- path_to_settings
    
    # this took care of "css" only, others have the same prefix
    if(input$output == "css"){
      settings$run$inputs[["pss"]][['path']]  <- gsub("css","pss", path_to_settings)
      settings$run$inputs[["site"]][['path']] <- gsub("css","site", path_to_settings)
    }
    
  }

  
  return(settings)
} # ic_process
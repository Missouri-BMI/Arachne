options(connectionObserver = NULL)
options(useFancyQuotes = FALSE)

remotes::install_github(repo = 'OHDSI/Achilles', ref='develop')

aresDataRoot <- "./ares_data/"
dbms <- "postgresql"
server  <- "localhost/arachne_datanode"
port <- "5432"
user <- "ohdsi-user" # Sys.getenv("user")
password <- "ohdsi-password" #Sys.getenv("password")
pathToDriver <-  "./drivers/"
vocabFileLoc      <- "./vocabulary_download_v5"
syntheaExecutable <- "./synthea-with-dependencies.jar"
syntheaOutputDirectory <- "./output/" 



DatabaseConnector::downloadJdbcDrivers(dbms, pathToDriver = pathToDriver)


cdmVersion <- "5.4"
syntheaVersion <- "3.3.0"

# setup run parameters
testKey <- format(Sys.time(), "%Y%m%d_%H%M")
# end configuration

# configure connection
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms     = dbms,
  server   = server,
  user     = user,
  password = password,
  pathToDriver = pathToDriver
)

populationSize <- 100

simulatedSources <- list(
  list(abbreviation="MU", sourceName="University of Missouri", geographySpecification="Missouri", population=populationSize)
#   list(abbreviation="KUMC", sourceName="University of Kansas Medical Center", geographySpecification="Kansas", population=1000),
#   list(abbreviation="WASHU", sourceName="Washington University in St. Louis", geographySpecification="Missouri", population=1000)
#   list(abbreviation="MCW", sourceName="Medical College of Wisconsin", geographySpecification="Wisconsin", population=populationSize),
#   list(abbreviation="UIOWA", sourceName="University of Iowa", geographySpecification="Iowa", population=populationSize) 
)


for (simulatedSource in simulatedSources) {
  writeLines(paste("Processing",simulatedSource$geographySpecification))
  
  # running synthea
  syntheaSimulateCommand <- paste0("java -jar \"", syntheaExecutable, "\" ",
                                   "-p ", simulatedSource$population, " ",
                                   "--exporter.fhir.transaction_bundle false ",
                                   "--exporter.csv.export true ",
                                   "--exporter.practitioner.fhir.export false ",
                                   "--exporter.hospital.fhir.export false ",
                                   "--exporter.fhir.export false ",
                                   "--exporter.years_of_history 20 ",
                                   "--exporter.baseDirectory ", syntheaOutputDirectory, simulatedSource$abbreviation, " ",
                                   "\"", simulatedSource$geographySpecification, "\"")
  system(syntheaSimulateCommand)
  
  # setup simulated source details
  cdmSourceName <- paste0("cdm_",tolower(simulatedSource$abbreviation),"_")
  nativeSourceName <- paste0("native_", tolower(simulatedSource$abbreviation),"_")
  cdmDatabaseSchema <- paste0(cdmSourceName, testKey)
  resultsDatabaseSchema <- paste0(cdmSourceName, testKey)
  nativeSchema <- paste0(nativeSourceName, testKey)
  syntheaFileLoc <- paste0(syntheaOutputDirectory, simulatedSource$abbreviation, "/csv")
  vocabularySchema <- cdmDatabaseSchema
  
  # create schemas
  connection <- DatabaseConnector::connect(connectionDetails)
  DatabaseConnector::executeSql(connection, paste("drop schema if exists ", cdmDatabaseSchema, "cascade"))
  DatabaseConnector::executeSql(connection, paste("drop schema if exists ", nativeSchema, "cascade"))
  DatabaseConnector::executeSql(connection, paste("create schema ", cdmDatabaseSchema))
  DatabaseConnector::executeSql(connection, paste("create schema ", nativeSchema))
  DatabaseConnector::disconnect(connection)
  
  # use the CommonDataModel package to create the CDM tables
  ETLSyntheaBuilder::CreateCDMTables(
    connectionDetails = connectionDetails,
    cdmSchema = cdmDatabaseSchema,
    cdmVersion = cdmVersion
  )
  
  # Load the native data into the CDM
  ETLSyntheaBuilder::LoadVocabFromCsv(
    connectionDetails,
    vocabularySchema,
    vocabFileLoc
    ) 

  # create & load the simulated synthea data - this is our native data
  ETLSyntheaBuilder::CreateSyntheaTables(
    connectionDetails = connectionDetails,
    syntheaSchema = nativeSchema,
    syntheaVersion = syntheaVersion
  )
  
  ETLSyntheaBuilder::LoadSyntheaTables(
    connectionDetails = connectionDetails,
    syntheaSchema = nativeSchema,
    syntheaFileLoc = syntheaFileLoc
  )
  
  ETLSyntheaBuilder::CreateMapAndRollupTables(
    connectionDetails = connectionDetails, 
    cdmSchema = cdmDatabaseSchema, 
    syntheaSchema = nativeSchema, 
    cdmVersion = cdmVersion, 
    syntheaVersion = syntheaVersion
  )
  
  ## Optional Step to create extra indices
  ETLSyntheaBuilder::CreateExtraIndices(
    connectionDetails = connectionDetails, 
    cdmSchema = cdmDatabaseSchema, 
    syntheaSchema = nativeSchema, 
    syntheaVersion = syntheaVersion
  )
  
  # run our ETL to create the CDM
  ETLSyntheaBuilder::LoadEventTables(
    connectionDetails = connectionDetails,
    cdmSchema = cdmDatabaseSchema,
    syntheaSchema = nativeSchema,
    cdmVersion = cdmVersion,
    syntheaVersion = syntheaVersion,
    cdmSourceName = simulatedSource$sourceName,
    cdmSourceAbbreviation = simulatedSource$abbreviation
  )
  
  releaseKey <- AresIndexer::getSourceReleaseKey(connectionDetails, cdmDatabaseSchema)
  datasourceReleaseOutputFolder <- file.path(aresDataRoot, releaseKey)
  
  # run achilles
  Achilles::achilles(
    cdmVersion = cdmVersion,
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    vocabDatabaseSchema = vocabularySchema,
    resultsDatabaseSchema = cdmDatabaseSchema,
    smallCellCount = 0
  )
  
  # run data quality dashboard
  dqResults <- DataQualityDashboard::executeDqChecks(
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    resultsDatabaseSchema = resultsDatabaseSchema,
    vocabDatabaseSchema = vocabularySchema,
    cdmVersion = cdmVersion,
    cdmSourceName = cdmSourceName,
    outputFile = "dq-result.json",
    outputFolder = datasourceReleaseOutputFolder
  )
  
  # Export Achilles results to Ares supported format
  Achilles::exportToAres(
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    resultsDatabaseSchema = resultsDatabaseSchema,
    vocabDatabaseSchema = vocabDatabaseSchema,
    outputPath = aresDataDirectory,
  )
  
  
  # perform temporal characterization
  outputFile <- file.path(datasourceReleaseOutputFolder, "temporal-characterization.csv")
  
  Achilles::getTemporalData(
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    resultsDatabaseSchema = resultsDatabaseSchema,
  )
  
  Achilles::performTemporalCharacterization(
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    resultsDatabaseSchema = resultsDatabaseSchema,
    outputFile = outputFile
  )
  
  # augment concept files with temporal characterization data
  AresIndexer::augmentConceptFiles(releaseFolder = file.path(aresDataRoot, releaseKey))
}

# build a network level index for all simulated sources
sourceFolders <- list.dirs(aresDataRoot,recursive=F)
AresIndexer::buildNetworkIndex(sourceFolders = sourceFolders, outputFolder = aresDataRoot)
AresIndexer::buildDataQualityIndex(sourceFolders = sourceFolders, outputFolder = aresDataRoot)
AresIndexer::buildNetworkUnmappedSourceCodeIndex(sourceFolders = sourceFolders, outputFolder = aresDataRoot)
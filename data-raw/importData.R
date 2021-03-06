library(tidyverse)
library(stringr)
library(dbplyr)

###################
###### BBS ########
###################

source("R/bbs_forecasting_functions.R")

#Adapted from get_bbs_data() from sourced scripts
get_bbs <- function(){
  data_path <- paste('./extdata/', 'bbs', '_data.csv', sep="")
  if (file.exists(data_path)){
    return(read_csv(data_path))
    print("yes csv")
  }
  else{
    if (!db_engine(action='check', db = "./extdata/bbsforecasting_old.sqlite", #doesn't work with latest bbs database, probably due to install issues
                   table_to_check = 'breed_bird_survey_counts')){
      print("no database")
      install_dataset('breed-bird-survey')
    }
    
    birds <- DBI::dbConnect(RSQLite::SQLite(), "./extdata/bbsforecasting_old.sqlite")
    
    #save database tables as table in R to use with tidyverse commands
    counts <- tbl(birds, "breed_bird_survey_counts")
    weather <- tbl(birds, "breed_bird_survey_weather")
    routes <- tbl(birds, "breed_bird_survey_routes")
    species <- tbl(birds, "breed_bird_survey_species") %>%
      select(-species_id) #drop the column that BBS is calling species_id (not the same as our species ID which is the AOU code)
    
    print('tables ran')
    
    #join all data into one table
    bbs <- left_join(weather, counts, by = c("year", "statenum", "route", "rpid", "year")) %>%
      left_join(routes, by = c("statenum", "route")) %>%
      left_join(species, by = "aou") %>%
      ###
      dplyr::filter(runtype == 1 & rpid == 101) %>%
      mutate(site_id = (statenum*1000) + route) %>%
      select(site_id, latitude, longitude, aou, year, speciestotal) %>%
      rename(species_id = aou, abundance = speciestotal, lat = latitude, long = longitude) %>%
      collect() 

    #clean up specie(i.e. combine subspecies, exclude poorly sampled species), see source script for details - probably doesn't work
    bbs_clean <- bbs %>% 
      filter_species() %>%
      group_by(site_id) %>%
      combine_subspecies() %>%
      #add taxonomy
      left_join(collect(species), by = c("species_id" = "aou")) %>%
      select (site_id, year, species_id, lat, long, abundance, genus, species, english_common_name) %>%
      rename (common_name = english_common_name) %>%
      unite(scientific, genus, species, sep = " ")
    
    #write.csv(bbs_clean, file = data_path, row.names = FALSE, quote = FALSE)
    return(bbs_clean)
    
  }
}

bbs_data <- get_bbs()

###################
####Trait Data#####
###################

bird_path <- system.file("extdata", "elton_traits/elton_traits_BirdFuncDat.csv", package = "functional.diversity")
mamm_path <- system.file("extdata", "elton_traits/elton_traits_MammFuncDat.csv", package = "functional.diversity")

if (bird_path == "") {
  dir.create("./extdata/elton_traits")
  rdataretriever::install("elton-traits", 'csv', data_dir = "data/elton_traits")
}

bird_trait <- read_csv(bird_path)
mamm_trait <- read_csv(mamm_path)


####################
### BBS & Trait ####
### Master CSV  ####
####################

get_bbs_compatible_sci_names <- function(){
  
  data_path <- paste('./data/', 'bbs_data_compatible.csv', sep = "")
  if (file.exists(data_path)){
    return(read_csv(data_path))
  }else{
    #join bbs and traits on scientific name to find taxonomic mismatches, 
    #and get a dataframe of taxonomic equivalancies based on common names
    sci_equivalent <- bbs_data %>% 
      select(scientific, common_name) %>%
      unique() %>%
      left_join(select(trait, scientific, english), by = "scientific") %>% #join on scientific name
      subset(is.na(english)) %>% #get rows where the scientic names didn't match
      select(scientific, common_name) %>% #select bbs sci name and common name
      left_join(select(trait, scientific, english), 
                by = c("common_name" = "english")) %>% #join bbs and trait data on common name to see taxanomic equivalents
      rename(bbs_sci = scientific.x, trait_sci = scientific.y) %>%
      drop_na()
    
    
    ## Yellow-rumped warbler = yellow-rumped warbler w/o commentary
    ## Black-throated Gray Warbler = Black-throated Grey Warbler
    ## Gray Hawk = grey hawk (technically different subspecies?)
    ## Pacific Wren and Winter Wren are grouped into one species Troglodytes troglodytes, Winter wren matches on common name, but Pacific wren needs new sci name
    ## Easter Yellow Wagtail = Yellow Wagtail
    ## Sagebrush sparrow and Bell's sparrow are grouped together as sage sparrow
    ## Woodhouse's scrub jay = Western scrub jay
    
    get_compatible_sci_names <- function(data, sci_equiv){
      #Create a new column called compat_sci that replaces BBS sci names with their trait data equivalent#
      
      #case when formula - one for each row of equivalencies 
      replace_form <- lapply(1:dim(sci_equiv)[1],function(var){ 
        formula(paste0('data$scientific == as.character(sci_equiv$bbs_sci[',
                       var, ']) ~ as.character(sci_equiv$trait_sci[', var,'])'))
      })
      
      #add special cases where neither common or scientific names match, but the species are the same
      ##still don't work, not sure why
      replace_form <- append(replace_form, 
                             c(formula('data$scientific == \'Setophaga coronata\' ~ \'Dendroica coronata\''), #Yellow-rumped Warbler
                               formula('data$scientific == \'Setophaga nigrescens\' ~ \'Dendroica nigrescens\''), #Black-throated Grey Warbler
                               formula('data$scientific == as.character(\'Buteo plagiatus\') ~ \'Buteo nitidus\''), #Grey Hawk
                               formula('data$scientific == as.character(\'Troglodytes pacificus\') ~ \'Troglodytes troglodytes\''), #Pacific Wren
                               formula('data$scientific == as.character(\'Motacilla tschutschensis\') ~ \'Motacilla flava\''), #Eastern Yellow Wagtail 
                               formula('data$scientific == as.character(\'Artemisiospiza nevadensis\') ~ \'Amphispiza belli\''), #Sagebrush sparrow
                               formula('data$scientific == as.character(\'Artemisiospiza belli\') ~ \'Amphispiza belli\''), #Bell's Sparrow
                               formula('data$scientific == as.character(\'Aphelocoma woodhouseii\') ~ \'Aphelocoma californica\'') #Woodhouse's Scrub jay
                             )
      )
      
      #add case for when there is no equivalence and we keep the original name
      replace_form <- append(replace_form, formula(paste0("TRUE ~ as.character(data$scientific)")))
      
      #add column
      data %>%
        mutate(compat_sci = case_when(!!!replace_form))
      
    }
    
    #get equivalence column for BBS data
    bbs_compat <- get_compatible_sci_names(bbs_data, sci_equivalent) %>%
      select(-scientific) %>%
      rename(scientific = compat_sci)
    
    #write.csv(bbs_compat, file = data_path, row.names = FALSE, quote = FALSE)
    return(bbs_compat)
  }
}

bbs <- get_bbs_compatible_sci_names()

####################
###   BioTime   ####
###  Database   ####
####################

path <- system.file("extdata", "biotime_query.csv", package = "functional.diversity")

if (path == "") {
  rdataretriever::install("biotime", "csv", data_dir = here("extdata"))
}

biotime <- read.csv(path)
names <- colnames(biotime)

biotime_clean <- biotime %>%
  select(-study_id) %>%
  magrittr::set_colnames(names[-length(names)]) %>%
  unite(genus_species, c("genus", "species"), sep = " ")

biotime_meta <- read.csv(system.file("extdata", "biotime_metadata.csv", package = "functional.diversity"))

biotime_data <- biotime_meta %>% 
  select(study_id, realm, climate, habitat, protected_area, taxa, organisms) %>%
  right_join(biotime_clean, by = "study_id")

devtools::use_data(bird_trait, mamm_trait, bbs, biotime_data)

#' RNAseqCNV_wrapper
#'
#' Wrapper for generating figures for analysis and preview figure
#'
#' @param config R script assigning variables needed for the analysis
#' @param metadata path to a metadata table with three columns. First colum represents sample names, second file names of count files, third file names of snv files.
#' @param adjust logical value, determines, whether the diploid boxplots should be centered around zero on y axis
#' @param arm_lvl logical value, determines, wheter arm_lvl figures should be printed (increases run-time significantly)
#' @param estimate_lab logical value, determines, whether CNV estimation should be plotted in the final figure
#' @param referData table, reference data for ensamble name annotation
#' @param keptSNP vector of SNPs to keep for the analysis
#' @param par_region table with pseudoautosomal regions, in order for these regions to be fitlered out
#' @param centr_refer table with centromeric locations per chromosome
#' @param weight_tab table with per-gene weight for adjusting the importance of each gene in calling CNA
#' @param model_gend model for estimating gender based on expression of certain genes on chromosome Y
#' @param model_dip model for estimating whether chromosome arm is diploid
#' @param model_alter model for estimating the CNV on chromosome arm
#' @param chroms vector of chromosomes to be analyzed
#' @param base_matrix matrix with rows being gene expression and columns DIPLOID samples. This matrix is used as a diploid reference.
#' @param base_column column names for base_matrix parameter
#' @param scale_cols colour scaling for box plot
#' @param dpRationChromEdge table with chromosome start and end base positions
#' @param minDepth minimal depth of of SNV to be kept
#' @param minReadCnt numeric value value used for filtering genes with low expression according to to formula: at least samp_prop*100 percent of samples have more reads than minReadCnt
#' @param samp_prop sample proportion which is required to have at least minReadCnt reads for a gene
#' @param weight_samp_prop proportion of samples to be kept according the their weight
#' @export RNAseqCNV_wrapper
RNAseqCNV_wrapper <- function(config, metadata, adjust = TRUE, arm_lvl = TRUE, estimate_lab = TRUE, referData = refDataExp, keptSNP = keepSNP, par_region = par_reg, centr_refer = centr_ref, weight_tab = weight_table, model_gend = model_gender, model_dip = model_dipl, model_alter = model_alt,
                              chroms = chrs, dipl_standard = diploid_standard, scale_cols = scaleCols, dpRatioChromEdge = dpRatioChrEdge, minDepth = 20, minReadCnt = 3, samp_prop = 0.8, weight_samp_prop = 1) {

  #Check the config file
  out_dir <- NULL
  count_dir <- NULL
  snv_dir <- NULL

  source(config, local = TRUE)
  if (is.null(out_dir) | is.null(count_dir) | is.null(snv_dir)) {
    stop("Incorrect config file format")
  } else if (!dir.exists(out_dir) | !dir.exists(snv_dir) | !dir.exists(count_dir)) {
    stop("Directory from config file does not exist")
  }

  #check metadata file
  metadata_tab = fread(metadata, header = FALSE)
  if (ncol(metadata_tab) != 3) {
    stop("The number of columns in metadata table should be 3")
  }

  #Create sample table
  sample_table = metadata_tab %>% mutate(count_path = file.path(count_dir, pull(metadata_tab, 2)), snv_path = file.path(snv_dir, pull(metadata_tab, 3)))

  #check files
  count_check <- file.exists(sample_table$count_path)
  snv_check <- file.exists(sample_table$snv_path)

  if (any(!c(count_check, snv_check))) {
    count_miss <- sample_table$count_path[!count_check]
    snv_miss <- sample_table$snv_path[!snv_check]

    files_miss <- paste0(c(count_miss, snv_miss), collapse = ", ")

    stop(paste0("File/s: ", files_miss, " not found"))
  }

  #Create estimation table
  est_table <- data.frame(sample = character(),
                          gender = factor(levels = c("female", "male")),
                          chrom_n = integer(),
                          type = factor(levels = c("diploid", "high hyperdiploid", "low hyperdiploid", "low hypodiploid", "near haploid", "high hypodiploid", "near diploid")),
                          alterations = character(), stringsAsFactors = FALSE)

  #Run the analysis for every sample in the table
  for(i in 1:nrow(sample_table)) {

    sample_name <- as.character(sample_table[i, 1])

    #load SNP data
    smpSNP <- prepare_snv(sample_table = sample_table, sample_num = i, centr_ref = centr_ref, minDepth = minDepth, chrs = chroms)

    #calculate normalized count values
    count_norm <- get_norm_exp(sample_table = sample_table, sample_num = i, diploid_standard = dipl_standard, minReadCnt = minReadCnt, samp_prop = samp_prop, weight_table = weight_tab, weight_samp_prop = weight_samp_prop)

    #calculate medians for analyzed genes
    pickGeneDFall <- get_med(count_norm = count_norm, refDataExp = referData)

    #filter SNP data base on dpSNP database
    smpSNPdata.tmp <- filter_snv(smpSNP[[1]], keepSNP = keptSNP)

    #analyze chromosome-level metrics (out-dated)
    smpSNPdata <- calc_chrom_lvl(smpSNPdata.tmp)

    #arm-level metrics
    smpSNPdata_a_2 <- calc_arm(smpSNPdata.tmp)

    count_norm_sel <- select(count_norm, !!quo(sample_name)) %>% mutate(ENSG = rownames(count_norm))

    #join reference data and weight data
    count_ns <- count_transform(count_ns = count_norm_sel, pickGeneDFall, refDataExp = referData, weight_table = weight_tab)

    #remove PAR regions
    count_ns <- remove_par(count_ns = count_ns, par_reg = par_region)

    #Calculate metrics for chromosome arms
    feat_tab <- get_arm_metr(count_ns = count_ns, smpSNPdata = smpSNPdata_a_2, sample_name = sample_names, centr_ref = centr_ref, chrs = chrs)

    #estimate gender
    count_ns_gend <- count_norm_sel %>% filter(ENSG %in% c("ENSG00000114374", "ENSG00000012817", "ENSG00000260197", "ENSG00000183878")) %>%  select(ENSG, !!quo(sample_name)) %>% spread(key = ENSG, value = !!quo(sample_name))
    gender = ifelse(randomForest:::predict.randomForest(model_gend, newdata = count_ns_gend, type = "class") == 1, "male", "female")

    #preprocess data for karyotype estimation and diploid level adjustement
    # model diploid level
    feat_tab$chr_status <- randomForest:::predict.randomForest(model_dip, feat_tab, type = "class")

    #exclude non-informative regions
    feat_tab_alt <- feat_tab %>%
      filter(arm != "p" | !chr %in% c(13, 14, 15, 21)) %>%
      metr_dipl()

    #model alteration on chromosome arms
    feat_tab_alt <- feat_tab_alt %>% mutate(alteration = as.character(randomForest:::predict.randomForest(model_alter, ., type = "class")))
    feat_tab_alt$alteration_prob <- apply(randomForest:::predict.randomForest(model_alter, feat_tab_alt, type = "prob"), 1, max)

    feat_tab_alt <- colour_code(feat_tab_alt) %>% group_by(chr) %>% mutate(alteration = as.character(alteration), chr_alt = as.character(ifelse(length(unique(alteration)) == 1, unique(alteration), "ab")))

    #estimate karyotype
    kar_list <- gen_kar_list(feat_tab_alt = feat_tab_alt, sample_name = sample_name, gender = gender)

    est_table <- rbind(est_table, kar_list)
    write.table(x = est_table, file = file.path(out_dir, "estimation_table.tsv"), sep = "\t")
    write.table(x = cbind(est_table , status = "not checked", comments = "none"), file = file.path(out_dir, "manual_an_table.tsv"), sep = "\t")


    #adjust for diploid level
    if (adjust == TRUE) {
      count_ns <-  adjust_dipl(feat_tab_alt, count_ns)
    }

    #calculate box plots for plotting
    box_wdt <- get_box_wdt(count_ns = count_ns, chrs = chroms, scaleCols = scale_cols)

    #adjust y axis limits
    ylim <- adjust_ylim(box_wdt = box_wdt, ylim = c(-0.4, 0.4))


    count_ns_final <- prep_expr(count_ns = count_ns, dpRatioChrEdge = dpRatioChromEdge, ylim = ylim, chrs = chroms)

    count_ns_final <- filter_expr(count_ns_final = count_ns_final, cutoff = 0.6)

    #Create per-sample folder for figures
    chr_dir = file.path(out_dir, sample_name)
    dir.create(path = chr_dir)

      #plot arm-level figures
      if(arm_lvl == TRUE) {

        chr_to_plot <- c(1:22, "X")

        centr_res <- rescale_centr(centr_ref, count_ns_final)


        #plot every chromosome
        for (i in chr_to_plot) {

          gg_exp_zoom <- plot_exp_zoom(count_ns_final = count_ns_final, centr_res = centr_res, plot_chr = i,  estimate = estimate_lab, feat_tab_alt = feat_tab_alt)

          yAxisMax_arm = get_yAxisMax(smpSNPdata = smpSNPdata, plot_chr = i)

          gg_snv_arm_p <- plot_snv_arm(smpSNPdata_a = smpSNPdata_a_2, plot_arm = "p", plot_chr = i, yAxisMax = yAxisMax_arm)

          gg_snv_arm_q <- plot_snv_arm(smpSNPdata_a = smpSNPdata_a_2, plot_arm = "q", plot_chr = i, yAxisMax = yAxisMax_arm)

          gg_arm <- chr_plot(p_snv = gg_snv_arm_p, q_snv = gg_snv_arm_q, arm_expr = gg_exp_zoom)

          ggsave(filename = file.path(chr_dir, paste0("chromosome_", i, ".png")), plot = gg_arm, device = "png", width = 20, height = 10, dpi = 100)

        }

      }

      gg_exp <- plot_exp(count_ns_final = count_ns_final, box_wdt = box_wdt, sample_name = sample_name, ylim = ylim, estimate = estimate_lab, feat_tab_alt = feat_tab_alt, gender = gender)

      gg_snv <- plot_snv(smpSNPdata, chrs = chroms, sample_name = sample_name)

      fig <- arrange_plots(gg_exp = gg_exp, gg_snv = gg_snv)

      ggsave(plot = fig, filename = file.path(chr_dir, paste0(sample_name, "_CNV_main_fig.png")), device = 'png', width = 16, height = 10, dpi = 200)

  }
}


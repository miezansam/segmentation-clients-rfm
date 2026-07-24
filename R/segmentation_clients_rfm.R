## ==============================================================================
## PROJET : SEGMENTATION DE LA CLIENTÈLE E-COMMERCE
## Méthode : Analyse RFM (Récence, Fréquence, Montant) + Clustering K-means
## Dataset : Online Retail (UCI Machine Learning Repository)
## Auteur  : YAO MIÉZAN SAM WILLIAM
## ==============================================================================

# IMPORTATION DES LIBRAIRIES

library(readxl)      # Import du fichier Excel
library(dplyr)        # Manipulation de données
library(lubridate)    # Gestion des dates
library(ggplot2)       # Visualisation
library(gridExtra)    # Assemblage de graphiques
library(factoextra)   # Clustering (nombre optimal de clusters, visualisation)
library(tidyr)        # Remise en forme des données (pivot_longer)


# 1. IMPORT DES DONNÉES

data <- read_excel("Online Retail.xlsx")


# 2. EXPLORATION DU DATASET

str(data)
summary(data)
glimpse(data)

## Valeurs manquantes par colonne
colSums(is.na(data))

## Quantités négatives
sum(data$Quantity < 0)

## Prix unitaires nuls ou négatifs
sum(data$UnitPrice <= 0)

## Nombre de clients uniques
n_distinct(data$CustomerID)

## Répartition des transactions par pays
table(data$Country)


# 3. NETTOYAGE DES DONNÉES

## Objectif : ne garder que les transactions valides (achats réels, client connu)

data_clean <- data %>%
  filter(!is.na(CustomerID)) %>%     # retirer les commandes sans client identifié
  filter(Quantity > 0) %>%           # retirer les retours (quantités négatives)
  filter(UnitPrice > 0) %>%          # retirer les prix aberrants
  mutate(
    InvoiceDate = as_datetime(InvoiceDate),
    TotalPrice  = Quantity * UnitPrice   # montant de la ligne de commande
  )

## Vérification post-nettoyage
str(data_clean)
nrow(data_clean)
n_distinct(data_clean$CustomerID)


# 4. CALCUL DES INDICATEURS RFM

## R = Récence   : nombre de jours depuis le dernier achat
## F = Fréquence : nombre de commandes distinctes
## M = Montant   : somme totale dépensée

# Date de référence : dernier jour du dataset + 1 jour
date_ref <- max(data_clean$InvoiceDate) + days(1)

rfm <- data_clean %>%
  group_by(CustomerID) %>%
  summarise(
    Recency   = as.numeric(difftime(date_ref, max(InvoiceDate), units = "days")),
    Frequency = n_distinct(InvoiceNo),
    Monetary  = sum(TotalPrice)
  ) %>%
  ungroup()

## Vérification
str(rfm)
summary(rfm)
head(rfm, 10)


# 5. DÉTECTION DES VALEURS ABERRANTES (MÉTHODE IQR)

## On visualise puis on quantifie les outliers sur les variables RFM brutes,
## avant toute transformation, pour objectiver le choix méthodologique
## qui suit (transformation logarithmique plutôt que suppression).

## Boxplots des variables RFM brutes
rfm %>%
  select(Recency, Frequency, Monetary) %>%
  pivot_longer(everything(), names_to = "Variable", values_to = "Valeur") %>%
  ggplot(aes(x = Variable, y = Valeur)) +
  geom_boxplot(fill = "#4C72B0", alpha = 0.7) +
  facet_wrap(~Variable, scales = "free") +
  theme_minimal() +
  ggtitle("Détection des valeurs aberrantes (méthode IQR), variables RFM brutes")

## Quantification des outliers par variable (bornes IQR classiques)
for (col in c("Recency", "Frequency", "Monetary")) {
  Q1 <- quantile(rfm[[col]], 0.25)
  Q3 <- quantile(rfm[[col]], 0.75)
  IQR_val <- Q3 - Q1
  borne_inf <- Q1 - 1.5 * IQR_val
  borne_sup <- Q3 + 1.5 * IQR_val
  n_out <- sum(rfm[[col]] < borne_inf | rfm[[col]] > borne_sup)
  cat(sprintf("%-12s : %d outliers (%.1f%%)\n", col, n_out, 100 * n_out / nrow(rfm)))
}


# 6. TRANSFORMATION LOGARITHMIQUE

## Les variables RFM sont fortement asymétriques.
## On applique log(1+x) pour réduire l'effet des valeurs extrêmes
## plutôt que de supprimer les clients concernés (ce sont des achats réels).

rfm_log <- rfm %>%
  mutate(
    Recency_log   = log1p(Recency),
    Frequency_log = log1p(Frequency),
    Monetary_log  = log1p(Monetary)
  )

head(rfm_log, 10)

## Comparaison visuelle avant / après transformation de la variable Monetary
p1 <- ggplot(rfm, aes(x = Monetary)) +
  geom_histogram(bins = 50) +
  ggtitle("Monetary (brut)")

p2 <- ggplot(rfm_log, aes(x = Monetary_log)) +
  geom_histogram(bins = 50) +
  ggtitle("Monetary (log)")

grid.arrange(p1, p2, ncol = 2)


# 7. STANDARDISATION

## Centrage-réduction des variables log-transformées, pour que chaque
## dimension pèse équitablement dans le calcul des distances (K-means).

rfm_scaled <- rfm_log %>%
  select(Recency_log, Frequency_log, Monetary_log) %>%
  scale() %>%
  as.data.frame()

summary(rfm_scaled)


# 8. DÉTERMINATION DU NOMBRE OPTIMAL DE CLUSTERS

set.seed(123)

## Méthode du coude (Within Sum of Squares)
fviz_nbclust(rfm_scaled, kmeans, method = "wss") +
  ggtitle("Méthode du coude")

## Score de silhouette moyen
fviz_nbclust(rfm_scaled, kmeans, method = "silhouette") +
  ggtitle("Score de silhouette")

## k = 4 retenu : bon compromis entre robustesse statistique
##                et richesse d'interprétation métier


# 9. CLUSTERING K-MEANS

set.seed(123)
k <- 4

km_result <- kmeans(rfm_scaled, centers = k, nstart = 25)

## Ajout du cluster à chaque client
rfm_final <- rfm_log %>%
  mutate(Cluster = as.factor(km_result$cluster))

## Taille de chaque cluster
table(rfm_final$Cluster)

## Profil moyen de chaque cluster (sur les valeurs réelles, non transformées)
rfm_final %>%
  group_by(Cluster) %>%
  summarise(
    n             = n(),
    Recency_moy   = mean(Recency),
    Frequency_moy = mean(Frequency),
    Monetary_moy  = mean(Monetary)
  )


# 10. VISUALISATION DES CLUSTERS

## Projection 2D des clusters (via ACP)
fviz_cluster(km_result, data = rfm_scaled,
             geom = "point", ellipse.type = "convex",
             palette = "jco", ggtheme = theme_minimal()) +
  ggtitle("Segmentation des clients (K-means, k=4)")

## Boxplots des variables RFM par cluster
rfm_final %>%
  select(Cluster, Recency, Frequency, Monetary) %>%
  pivot_longer(cols = c(Recency, Frequency, Monetary),
               names_to = "Variable", values_to = "Valeur") %>%
  ggplot(aes(x = Cluster, y = Valeur, fill = Cluster)) +
  geom_boxplot() +
  facet_wrap(~Variable, scales = "free") +
  theme_minimal() +
  ggtitle("Distribution des variables RFM par cluster")

## Effectif de clients par cluster (diagramme en barres)
ggplot(rfm_final, aes(x = Cluster, y = after_stat(count), fill = Cluster)) +
  geom_bar() +
  labs(title = "Nombre de clients par cluster",
       x = "Cluster", y = "Effectif") +
  theme_minimal()


# 11. VALIDATION PAR CLUSTERING HIÉRARCHIQUE

## Sur un échantillon car le calcul serait trop lourd sur les 4338 clients,
## on vérifie que la structure en 4 groupes est cohérente avec le K-means.

set.seed(123)

sample_idx  <- sample(1:nrow(rfm_scaled), 500)
rfm_sample  <- rfm_scaled[sample_idx, ]

dist_matrix <- dist(rfm_sample, method = "euclidean")
hc <- hclust(dist_matrix, method = "ward.D2")

## Dendrogramme
plot(hc, labels = FALSE, main = "Dendrogramme (échantillon 500 clients)",
     xlab = "", sub = "")
rect.hclust(hc, k = 4, border = "red")


# 12. ATTRIBUTION DES LABELS MÉTIER

segment_map <- rfm_final %>%
  group_by(Cluster) %>%
  summarise(Monetary_moy = mean(Monetary)) %>%
  arrange(desc(Monetary_moy)) %>%
  mutate(Segment = c("Champions", "Fidèles réguliers", 
                     "Récents / occasionnels", "Inactifs / perdus")[row_number()])

rfm_final <- rfm_final %>% left_join(segment_map %>% select(Cluster, Segment), by = "Cluster")

## Vérification finale
table(rfm_final$Segment)


# 13. EXPORT DES RÉSULTATS

## Export CSV pour archivage / réutilisation
write.csv(rfm_final, "rfm_segmentation_finale.csv", row.names = FALSE)

## Sauvegarde des objets R (pour reprise ultérieure sans tout relancer)
saveRDS(list(rfm_final = rfm_final, km_result = km_result, hc = hc),
        "resultats_segmentation.RDS")
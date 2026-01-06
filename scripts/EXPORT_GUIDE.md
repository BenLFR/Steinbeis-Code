# Guide d'Export des Heures Projet (TKS)

## 🎯 Objectif

Exporter les heures TKS pour n'importe quel projet avec détail par période (mois, semestre, etc.) comme dans les rapports Excel de Stella.

## 📁 Fichiers Disponibles

### Option 1: Export avec Périodes (RECOMMANDÉ)
**Script**: `scripts/export_project_hours_with_periods.R`

Exporte les heures avec découpage temporel pour voir les détails comme Stella.

**Paramètres**:
- `project_name`: Nom du projet (ex: "ROBIN", "SEADE")
- `start_date`: Date début (ex: "2024-01-01")
- `end_date`: Date fin (ex: "2024-12-31")
- `period_split`: Type de découpage
  - `"month"` ✅ **RECOMMANDÉ** - Détail par mois (maximum de détail)
  - `"semester"` - Par semestre (Jan-Jun / Jul-Dec)
  - `"quarter"` - Par trimestre (Q1, Q2, Q3, Q4)

**Exemples**:

```r
# ROBIN 2024 par mois
project_name <- "ROBIN"
start_date <- "2024-01-01"
end_date <- "2024-12-31"
period_split <- "month"
source("scripts/export_project_hours_with_periods.R")
```

```r
# SEADE 2024 par semestre
project_name <- "SEADE"
start_date <- "2024-01-01"
end_date <- "2024-12-31"
period_split <- "semester"
source("scripts/export_project_hours_with_periods.R")
```

### Option 2: Export Simple (Agrégé)
**Script**: `scripts/export_project_hours.R`

Export sans découpage temporel - tout agrégé par personne + WP.

⚠️ **Attention**: Perd le détail des périodes! Utilisez Option 1 si vous devez comparer avec Stella.

## 📊 Fichiers Générés

Chaque export crée 2 fichiers CSV dans `data/x/Database/ben/qa/`:

1. **`{projet}_hours_summary_{date}.csv`**
   - Total des heures par personne
   - Format: du_id, employee, total_hours

2. **`{projet}_hours_by_period_{date}.csv`** (avec périodes)
   - Détail par personne + WP + période
   - Format: du_id, employee, dwp_id, wp_title, period, min_date, max_date, n_entries, hours

Exemple pour ROBIN 2024 par mois:
```
robin_hours_summary_20240101_20241231.csv       (9 lignes - par personne)
robin_hours_by_period_20240101_20241231.csv    (111 lignes - par personne x WP x mois)
```

## 🎬 Exemples Rapides

### ROBIN 2024 (par mois)
```r
source("scripts/export_robin_2024_by_month.R")
```

### SEADE 2024 (créer le script)
```r
# Créer scripts/export_seade_2024_by_month.R
project_name <- "SEADE"
start_date <- "2024-01-01"
end_date <- "2024-12-31"
period_split <- "month"
source("scripts/export_project_hours_with_periods.R")
```

Puis:
```r
source("scripts/export_seade_2024_by_month.R")
```

## ✅ Validation avec Stella

Pour comparer vos résultats avec l'Excel de Stella:

1. Exporter avec `period_split = "month"` pour avoir maximum de détail

2. Ouvrir le fichier `{projet}_hours_by_period_{date}.csv`

3. Pour chaque personne + WP, agréger les mois selon les périodes de Stella

Exemple Clémentine Roth, WP3:
- Stella période 1 (Jan-Fév): Sommer mois 01 + 02 = 19h ✓
- Stella période 2 (Mar-Déc): Sommer mois 03-12 = 249h ✓

## 🔍 Troubleshooting

**Q: Les totaux ne matchent pas Stella**
- Vérifiez que les périodes sont identiques (dates début/fin)
- Utilisez découpage "month" puis agrégez manuellement
- Vérifiez que la base de données est à jour

**Q: Certains WPs manquent**
- Normal si pas d'heures dans la période spécifiée
- Vérifiez dwp_start/dwp_end du WP dans d_workpackage

**Q: Trop de lignes dans le CSV**
- Avec "month": beaucoup de lignes (détail maximum)
- Utilisez Excel/R pour agréger selon vos besoins
- Ou changez period_split à "semester"

## 📝 Notes Importantes

✅ **Heures calculées = dwt_worktime (TKS booked time)**
- Pas dérivées des timestamps (dwt_start/dwt_end)
- Utilise nww_worktime_seconds pour allocation WP
- Rescaling appliqué pour garantir cohérence

✅ **Périodes basées sur dwt_date**
- Date réelle de l'entrée de temps
- Pas sur les dates de réservation WP

✅ **Aucune perte de données**
- Export mensuel conserve TOUT
- Possibilité d'agréger comme souhaité après export

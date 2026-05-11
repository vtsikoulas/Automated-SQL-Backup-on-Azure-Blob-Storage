# Αυτοματοποιημένο Backup σε Azure Blob Storage με Striping

## Επισκόπηση
Αυτό το T-SQL script αυτοματοποιεί τη δημιουργία full backup για όλες τις online βάσεις δεδομένων σε Azure Blob Storage.
Υπολογίζει δυναμικά τον αριθμό stripes βάσει μεγέθους και δημιουργεί έτοιμες εντολές backup.

## Σκοπός
- **Αυτοματοποίηση** backup για όλες τις online βάσεις (εκτός tempdb/model)
- **Διαχείριση μεγάλων βάσεων** με αυτόματο striping σε πολλαπλά blob αρχεία
- **Βελτιστοποίηση απόδοσης** με compression, optimized transfer sizes και παράλληλο striping
- **Τήρηση ορίων Azure** (195GB ανά block blob, μέγιστο 64 stripes)

## Προαπαιτούμενα

| Απαίτηση | Λεπτομέρειες |
|----------|-------------|
| **Έκδοση SQL Server** | 2016 (v13) ή νεότερη |
| **Azure Credential** | Πρέπει να δημιουργηθεί με SAS token (γραμμές 10-13) |
| **Δικαιώματα** | Απαιτείται BACKUP DATABASE permission |
| **Δίκτυο** | Συνδεσιμότητα με Azure Blob Storage |

## Παράμετροι Ρύθμισης

| Παράμετρος | Τιμή | Περιγραφή |
|-----------|------|-----------|
| `@BaseURL` | URL container | URL του Azure Blob container |
| `@MaxStripeSizeGB` | 195 GB | Όριο Azure block blob |
| `@MaxStripes` | 64 | Όριο striping SQL Server |
| `@MaxTransferSize` | 4 MB | Βελτιστοποίηση δικτυακής μεταφοράς |
| `@BlockSize` | 64 KB | Βελτιστοποίηση I/O |

## Βασικές Λειτουργίες

### 1. Έλεγχος Έκδοσης (Γραμμές 17-23)
Επαληθεύει ότι ο SQL Server είναι 2016+ για υποστήριξη block blob και striping.

### 2. Ανακάλυψη Βάσεων Δεδομένων (Γραμμές 35-53)
- Ερωτά τα `sys.databases` και `sys.master_files`
- Υπολογίζει το πραγματικό μέγεθος σε GB
- Εξαιρεί tempdb, model και offline βάσεις
- Καταγράφει το recovery model για προειδοποιήσεις

### 3. Λογική Striping (Γραμμές 43-51)

| Μέγεθος Βάσης | Αριθμός Stripes |
|---------------|----------------|
| ≤ 195 GB | 1 stripe |
| > 195 GB | CEILING(SizeGB / 195) stripes |
| > 12.480 GB | Μέγιστο 64 stripes (ανώτατο όριο) |

### 4. Έλεγχος Μέγιστου Μεγέθους (Γραμμές 58-63)
Προειδοποιεί αν κάποια βάση υπερβαίνει τα 12.480 GB (195 × 64), που δεν μπορεί να υποστηριχθεί.

### 5. Δυναμική Δημιουργία Εντολών Backup (Γραμμές 65-140)
Για κάθε βάση:
- **Ένα stripe** (≤195GB): Ένα αρχείο `.bak`
- **Πολλαπλά stripes** (>195GB): Πολλαπλά αρχεία `_1.bak`, `_2.bak`, κλπ.
- **Μορφή ονόματος**: `ServerName_DatabaseName_YYYY-MM-DD_HHmmss[_stripe].bak`

### 6. Προειδοποίηση Recovery Model (Γραμμές 100-105)
Ειδοποιεί αν η βάση χρησιμοποιεί FULL recovery model, υπενθυμίζοντας τη στρατηγική transaction log backup.

## Επιλογές Backup

| Επιλογή | Σκοπός |
|---------|--------|
| `COMPRESSION` | Μείωση μεγέθους backup και χρόνου μεταφοράς |
| `MAXTRANSFERSIZE = 4MB` | Βελτιστοποίηση μεταφοράς Azure |
| `BLOCKSIZE = 65536` | Ευθυγράμμιση με blob storage blocks |
| `NOFORMAT, NOINIT` | Επιτρέπει λειτουργίες append |
| `STATS = 1` | Αναφορά προόδου (ανά 1%) |

## Οδηγίες Χρήσης

### Βήμα 1: Δημιουργία Credential (Μία Φορά)
Αφαιρέστε τα σχόλια και εκτελέστε τις γραμμές 10-13 με το πραγματικό SAS token:

````````
-- Δημιουργία credential για Azure Blob Storage
-- Αφαιρέστε το σχόλιο και εισάγετε το πραγματικό SAS token
/*
CREATE CREDENTIAL [MyAzureBlobStorageCredential]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
SECRET = '<Your_SASToken>'
FOR CRYPTOGRAPHIC ENCRYPTION;
*/
````````

### Βήμα 2: Επισκόπηση Εντολών
Εκτελέστε το script για να δείτε:
- Κατάλογο βάσεων με μεγέθη και αριθμό stripes
- Παραγόμενες εντολές BACKUP DATABASE
- Προειδοποιήσεις για FULL recovery βάσεις ή υπερμεγέθεις βάσεις

### Βήμα 3: Εκτέλεση Backups
- **Επιλογή Α:** Αντιγραφή/Επικόλληση μεμονωμένων εντολών
- **Επιλογή Β:** Αφαίρεση σχολίου στη γραμμή 130 (`EXEC(@SQL)`) για αυτόματη εκτέλεση

## Παράδειγμα Εξόδου
````````
Για παράδειγμα, αν η βάση δεδομένων ονομάζεται `MyDatabase` και ο server `MyServer`, το backup θα αποθηκευτεί ως:

`MyServer_MyDatabase_2023-10-04_153000.bak`

Αν η βάση είναι μεγαλύτερη από 195 GB, θα γίνουν πολλά backup αρχεία, π.χ.

`MyServer_MyDatabase_2023-10-04_153000_1.bak`
`MyServer_MyDatabase_2023-10-04_153000_2.bak`

````````

## Περιορισμοί & Προειδοποιήσεις

| ⚠️ Περιορισμός | Περιγραφή |
|---------------|-----------|
| Μέγιστο μέγεθος backup | 12.480 GB (195GB × 64 stripes) |
| FULL recovery model | Ελέγξτε τη στρατηγική transaction log backup |
| Εξάρτηση δικτύου | Απαιτεί σταθερή σύνδεση με Azure |
| Κόστος | Ισχύουν χρεώσεις Azure storage και egress |
| Χρόνος εκτέλεσης | Μεγάλα striped backups μπορεί να διαρκέσουν πολύ |

## Βέλτιστες Πρακτικές

1. **Δοκιμάστε τα credentials** πριν τη χρήση σε production
2. **Προγραμματίστε σε maintenance windows** για μεγάλες βάσεις
3. **Παρακολουθήστε το κόστος Azure** και τις πολιτικές retention
4. **Υλοποιήστε transaction log backups** για FULL recovery βάσεις
5. **Επαληθεύστε τα backups** με `RESTORE VERIFYONLY`
6. **Τεκμηριώστε τη λήξη** και ανανέωση του SAS token

## Στοιχεία Συντήρησης

| Πεδίο | Τιμή |
|-------|------|
| **Συγγραφέας** | Τσικούλας Βασίλης (vtsikoulas@impact.gr) |
| **Οργανισμός** | Entersoftone |
| **Ημερομηνία** | 2026-05 |

---
*Αυτό το script δημιουργεί μόνο εντολές — αφαιρέστε το σχόλιο στη γραμμή 130 για αυτόματη εκτέλεση.*

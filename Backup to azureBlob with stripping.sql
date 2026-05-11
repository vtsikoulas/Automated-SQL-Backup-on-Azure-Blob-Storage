
--Proof of concept για sql backup σε azure blob storage βάσης μεγέθους 1,5 TB.-- 

--Azure Blob Storage block blobs έχουν περιορισμό μεγέθους στα 195 GB. 
--Εάν η βάση δεδομένων σας είναι μεγαλύτερη από 195 GB, θα πρέπει να χρησιμοποιήσετε stripped backup παρέχοντας πολλαπλά URL όπου θα τοποθετηθούν τμήματα του backup.
--Διαβάστε τα παρακάτω links για να κατανοήσετε τον περιορισμό των 195 GB και την αποφυγή του Error-1117 the request could not be performed because of an I/O device error.

--https://learn.microsoft.com/en-us/archive/blogs/sqlcat/backing-up-a-vldb-to-azure-blob-storage
--Backing up a VLDB to Azure Blob Storage
--    Article
--    03/10/2017
--Reviewed by: Pat Schaefer, Rajesh Setlem, Xiaochen Wu, Murshed Zaman
--All SQL Server versions starting from SQL Server 2012 SP1 CU2 support Backup to URL, which allows storing SQL Server backups in Azure Blob Storage. 
--In SQL Server 2016, several improvements to Backup to URL were made, including the ability to use block blobs in addition to page blobs, and the ability to create striped backups (if using block blobs). 
--Prior to SQL Server 2016, the maximum backup size was limited to the maximum size of a single page blob, which is 1 TB.
--With striped backups to URL in SQL Server 2016, the maximum backup size can be much larger. Each block blob can grow up to 195 GB; with 64 backup devices,
--which is the maximum that SQL Server supports, that allows backup sizes of 195 GB * 64 = 12.19 TB.
--(As an aside, the latest version of the Blob Storage REST API allows block blob sizes up to 4.75 TB, as opposed to 195 GB in the previous version of the API. 
--However, SQL Server does not use the latest API yet.)
--In a recent customer engagement, we had to back up a 4.5 TB SQL Server 2016 database to Azure Blob Storage. Backup compression was enabled, 
--and even with a modest compression ratio of 30%, 20 stripes that we used would have been more than enough to stay within the limit of 195 GB per blob.
--Unexpectedly, our initial backup attempt failed. In the SQL Server error log, the following error was logged:
--Write to backup block blob device https://storageaccount.blob.core.windows.net/backup/DB\_part14.bak failed. Device has reached its limit of allowed blocks.
--When we looked at the blob sizes in the backup storage container (any storage explorer tool can be used, e.g. Azure Storage Explorer), 
--the blob referenced in the error message was slightly over 48 GB in size, which is about four times smaller than the maximum blob size of 195 GB that Backup to URL can create.
--To understand what was going on, it was helpful to re-read the “About Block Blobs” section of the documentation. To quote the relevant part: 
--“Each block can be a different size, up to a maximum of 100 MB (4 MB for requests using REST versions before 2016-05-31 [which is what SQL Server is using]),
--and a block blob can include up to 50,000 blocks.”
--If we take the error message literally, and there is no reason why we shouldn’t, we must conclude that the referenced blob has used all 50,000 blocks.
--That would mean that the size of each block is 1 MB (~48 GB / 50000), not the maximum of 4 MB that SQL Server could have used with the version of REST API it currently supports.
--How can we make SQL Server use larger block sizes, specifically 4 MB blocks? Fortunately, this is as simple as using the MAXTRANSFERSIZE parameter in the BACKUP DATABASE statement. 
--For 4 MB blocks, we used the following statement:

--ΠΡΟΣΟΧΗ. 
--Το παρακάτω θα πάρει full backup. Σε περίπτωση που το recovery model είναι full, δεν αντικαθιστά σε καμία περίπτωση την ανάγκη για differencing & transaction log backup. 
--Μπορεί να χρησιμοποιηθεί και για τα παραπάνω αλλά θα πρέπει να γίνει προσεκτικός έλεγχος και σχεδιασμός μαζί με μέτρηση της ταχύτητας ολοκλήρωσης καθώς και 
--fall back plan σε περίπτωση απώλειας σύνδεσης ή δικαιωμάτων μπρος το Storage. 
--Γενικά, όταν έχουμε full recovery model, καλό είναι να το συζητάμε και μαζί για να βρεθεί η βέλτιστή λύση. 
--Vailis Tsikoulas vtsikoulas@impact.gr


-- Δημιουργία Credential για το Azure Blob Storage, με όνομα το URL του container και τύπο ταυτοποίησης Shared Access Signature (SAS) και το κλειδί που δημιουργήσαμε στο Azure Portal.
USE [master]
GO
CREATE CREDENTIAL [https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups] WITH IDENTITY = N'Shared Access Signature', SECRET = N'123'
GO
--Παρακάτω το πραγματικό script για μία βάση 1,5ΤΒ. 
--Χρειάστηκαν 5 ώρες & 28 λεπτά για την ολοκλήρωση 
 
BACKUP DATABASE [MyData_EFOOD] TO  
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_1.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_2.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_3.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_4.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_5.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_6.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_7.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_8.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_9.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_10.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_11.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_12.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_13.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_14.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_15.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_16.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_17.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_18.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_19.bak',
URL = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups/mydata_efood_backup_2025_03_06_20.bak' 

WITH NOFORMAT,NOINIT,  
NAME = N'MyData_EFOOD-Full Database Backup', NOSKIP, NOREWIND, NOUNLOAD, COMPRESSION, MAXTRANSFERSIZE = 4194304, BLOCKSIZE = 65536, 
STATS = 1
GO

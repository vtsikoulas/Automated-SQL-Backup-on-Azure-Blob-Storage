-- =============================================================================
-- Τίτλος    : Αυτοματοποιημένο Backup SQL Server σε Azure Blob Storage με Striping
-- Συγγραφέας : Τσικούλας Βασίλης (vtsikoulas@impact.gr) | Entersoftone
-- Ημερομηνία : 2026-05
-- =============================================================================
-- Περιγραφή:
--   Δημιουργεί αυτόματα εντολές FULL backup για όλες τις online βάσεις
--   δεδομένων απευθείας σε Azure Blob Storage. Υπολογίζει δυναμικά τον
--   αριθμό stripes βάσει μεγέθους, τηρώντας τα όρια Azure και SQL Server.
--
-- Απαιτήσεις:
--   - SQL Server 2016 (v13) ή νεότερη
--   - Azure Blob Storage credential με SAS token (βλ. Βήμα 1 παρακάτω)
--   - Δικαιώματα BACKUP DATABASE
--
-- Μορφή ονόματος αρχείου : ServerName_DatabaseName_YYYY-MM-DD_HHmmss[_N].bak
-- Μέγιστο μέγεθος stripe : 195 GB (όριο Azure block blob)
-- Μέγιστος αριθμός stripes: 64 (όριο SQL Server)
--
-- Για αυτόματη εκτέλεση των εντολών backup (αντί απλής εκτύπωσης),
-- αφαιρέστε το σχόλιο από τη γραμμή EXEC(@SQL) μέσα στον cursor loop.
-- =============================================================================


-- =============================================================================
-- ΒΗΜΑ 1: Δημιουργία Credential Azure Blob Storage (ΜΟΝΟ ΜΙΑ ΦΟΡΑ)
-- =============================================================================
-- Αντικαταστήστε τα παρακάτω placeholders με τα δικά σας στοιχεία και
-- αφαιρέστε τα σχόλια για να εκτελέσετε τις εντολές.
-- Το SAS token πρέπει να ξεκινά με 'sp=...' (χωρίς το αρχικό '?').
--USE [master]
--GO
--CREATE CREDENTIAL [https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER]
--    WITH IDENTITY = N'Shared Access Signature',
--    SECRET = N'sp=...'   -- Εισάγετε εδώ το SAS token σας
--GO



-- =============================================================================
-- Έλεγχος έκδοσης SQL Server (απαιτείται 2016+ για block blob και striping)
-- =============================================================================
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 13
BEGIN
    PRINT N'** ΣΦΑΛΜΑ: Εντοπίστηκε SQL Server ' + CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50))
        + N'. Το backup σε URL με block blobs και striping απαιτεί SQL Server 2016 (v13) ή νεότερη. **';
    PRINT N'** Η εκτέλεση του script ακυρώθηκε. **';
    RETURN;
END

-- =============================================================================
-- Παράμετροι ρύθμισης — τροποποιήστε πριν την εκτέλεση
-- =============================================================================
DECLARE @BaseURL         NVARCHAR(500) = N'https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER';
DECLARE @ServerName      NVARCHAR(128) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));
DECLARE @DateSuffix      NVARCHAR(50)  = FORMAT(GETDATE(), 'yyyy-MM-dd_HHmmss');
DECLARE @MaxStripeSizeGB INT           = 195;     -- Όριο Azure block blob σε GB
DECLARE @MaxStripes      INT           = 64;      -- Μέγιστος αριθμός stripes (SQL Server)
DECLARE @MaxTransferSize INT           = 4194304; -- 4 MB — βελτιστοποίηση δικτυακής μεταφοράς
DECLARE @BlockSize       INT           = 65536;   -- 64 KB — βελτιστοποίηση I/O

-- =============================================================================
-- Συλλογή πληροφοριών βάσεων δεδομένων
-- =============================================================================
SELECT 
    d.name AS DatabaseName,
    CAST(SUM(mf.size) * 8.0 / 1024 / 1024 AS DECIMAL(10,2)) AS SizeGB,
    d.recovery_model_desc AS RecoveryModel,
    CASE 
        WHEN CAST(SUM(mf.size) * 8.0 / 1024 / 1024 AS DECIMAL(10,2)) > @MaxStripeSizeGB 
        THEN 
            CASE 
                WHEN CEILING(CAST(SUM(mf.size) * 8.0 / 1024 / 1024 AS DECIMAL(10,2)) / @MaxStripeSizeGB) > @MaxStripes
                THEN @MaxStripes
                ELSE CAST(CEILING(CAST(SUM(mf.size) * 8.0 / 1024 / 1024 AS DECIMAL(10,2)) / @MaxStripeSizeGB) AS INT)
            END
        ELSE 1
    END AS NumberOfStripes
INTO #DBInfo
FROM sys.databases d
JOIN sys.master_files mf ON d.database_id = mf.database_id
WHERE d.name NOT IN ('tempdb', 'model')  -- Εξαίρεση system databases
  AND d.state = 0                         -- Μόνο ONLINE βάσεις
GROUP BY d.name, d.recovery_model_desc;

-- Εμφάνιση αποτελεσμάτων (βάσεις, μεγέθη, αριθμός stripes)
SELECT * FROM #DBInfo ORDER BY SizeGB DESC;

-- Έλεγχος για βάσεις που υπερβαίνουν το μέγιστο υποστηριζόμενο μέγεθος backup
IF EXISTS (SELECT 1 FROM #DBInfo WHERE SizeGB > (@MaxStripeSizeGB * @MaxStripes))
BEGIN
    PRINT N'** ΣΦΑΛΜΑ: Μία ή περισσότερες βάσεις υπερβαίνουν το μέγιστο μέγεθος backup των '
        + CAST(@MaxStripeSizeGB * @MaxStripes AS NVARCHAR(20))
        + N' GB (195 GB x 64 stripes) και δεν μπορούν να γίνουν backup με αυτή τη μέθοδο. **';
    PRINT N'';
END

-- =============================================================================
-- Δυναμική δημιουργία εντολών backup (από μεγαλύτερη σε μικρότερη βάση)
-- =============================================================================
DECLARE @DBName        NVARCHAR(256);
DECLARE @SizeGB        DECIMAL(10,2);
DECLARE @Stripes       INT;
DECLARE @RecoveryModel NVARCHAR(60);
DECLARE @SQL           NVARCHAR(MAX);
DECLARE @i             INT;

DECLARE db_cursor CURSOR FOR
    SELECT DatabaseName, SizeGB, NumberOfStripes, RecoveryModel 
    FROM #DBInfo 
    ORDER BY SizeGB DESC;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DBName, @SizeGB, @Stripes, @RecoveryModel;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Προειδοποίηση για βάσεις σε FULL recovery model (απαιτείται και transaction log backup)
    IF @RecoveryModel = N'FULL'
    BEGIN
        PRINT N'-- ** ΠΡΟΣΟΧΗ: Η βάση [' + @DBName + N'] βρίσκεται σε FULL recovery model. '
            + N'Βεβαιωθείτε ότι εκτελείτε και transaction log backups. **';
    END

    PRINT N'-- Βάση: ' + @DBName + N' | Μέγεθος: ' + CAST(@SizeGB AS NVARCHAR(20))
        + N' GB | Stripes: ' + CAST(@Stripes AS NVARCHAR(10))
        + N' | Recovery: ' + @RecoveryModel;

    SET @SQL = N'BACKUP DATABASE ' + QUOTENAME(@DBName) + N' TO ' + CHAR(13) + CHAR(10);

    IF @Stripes = 1
    BEGIN
        -- Ένα μόνο αρχείο backup (βάση ≤ 195 GB)
        SET @SQL = @SQL + N'URL = N''' + @BaseURL + N'/'
            + @ServerName + N'_' + @DBName + N'_' + @DateSuffix + N'.bak''' + CHAR(13) + CHAR(10);
    END
    ELSE
    BEGIN
        -- Πολλαπλά αρχεία backup / striping (βάση > 195 GB)
        SET @i = 1;
        WHILE @i <= @Stripes
        BEGIN
            SET @SQL = @SQL + N'URL = N''' + @BaseURL + N'/' 
                + @ServerName + N'_' + @DBName + N'_' + @DateSuffix + N'_' + CAST(@i AS NVARCHAR(10)) + N'.bak''';
            IF @i < @Stripes
                SET @SQL = @SQL + N',' + CHAR(13) + CHAR(10);
            ELSE
                SET @SQL = @SQL + CHAR(13) + CHAR(10);
            SET @i = @i + 1;
        END
    END

    SET @SQL = @SQL + N'WITH NOFORMAT, NOINIT, ' + CHAR(13) + CHAR(10)
        + N'NAME = N''' + @DBName + N'-Full Database Backup'', ' + CHAR(13) + CHAR(10)
        + N'NOSKIP, NOREWIND, NOUNLOAD, COMPRESSION, ' + CHAR(13) + CHAR(10)
        + N'MAXTRANSFERSIZE = ' + CAST(@MaxTransferSize AS NVARCHAR(20)) + N', '
        + N'BLOCKSIZE = ' + CAST(@BlockSize AS NVARCHAR(20)) + N', ' + CHAR(13) + CHAR(10)
        + N'STATS = 1;';

    PRINT @SQL;
    PRINT N'GO';
    PRINT N'';

    -- Αφαιρέστε το σχόλιο στην επόμενη γραμμή για αυτόματη εκτέλεση του backup:
    -- EXEC(@SQL);

    FETCH NEXT FROM db_cursor INTO @DBName, @SizeGB, @Stripes, @RecoveryModel;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DROP TABLE #DBInfo;
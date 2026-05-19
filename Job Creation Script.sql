-- Created by GitHub Copilot in SSMS - review carefully before executing
-- =============================================================================
-- SQL Agent Job: Αυτοματοποιημένο Nightly Backup σε Azure Blob Storage
-- Συγγραφέας : Τσικούλας Βασίλης (vtsikoulas@impact.gr) | Entersoftone
-- =============================================================================
-- ΠΡΙΝ ΤΗΝ ΕΚΤΕΛΕΣΗ:
--   1) Αντικαταστήστε το @BaseURL με το δικό σας Azure Blob Storage URL
--   2) Βεβαιωθείτε ότι υπάρχει το credential στο τέλος
--   3) Βεβαιωθείτε ότι ο SQL Server Agent είναι ενεργός
-- =============================================================================

-- Διαγραφή υπάρχοντος job αν υπάρχει
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'Nightly Azure Blob Backup - All Databases with Striping')
BEGIN
    EXEC msdb.dbo.sp_delete_job 
        @job_name = N'Nightly Azure Blob Backup - All Databases with Striping',
        @delete_unused_schedule = 1;
END
GO

-- =============================================================================
-- Δημιουργία Job, Step, Schedule
-- =============================================================================
DECLARE @jobId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job 
    @job_name        = N'Nightly Azure Blob Backup - All Databases with Striping',
    @enabled         = 1,
    @description     = N'Αυτοματοποιημένο full backup όλων των online βάσεων σε Azure Blob Storage με δυναμικό striping. Εκτελείται καθημερινά στη 01:00.',
    @category_name   = N'Database Maintenance',
    @owner_login_name = N'sa',
    @job_id          = @jobId OUTPUT;

-- =============================================================================
-- Step 1: Full Backup με Striping
-- ΣΗΜΕΙΩΣΗ: Χρήση @Q = CHAR(39) μέσα στο step για αποφυγή πολυεπίπεδων quotes
-- =============================================================================
EXEC msdb.dbo.sp_add_jobstep 
    @job_id              = @jobId,
    @step_name           = N'Full Backup All Databases to Azure Blob with Striping',
    @step_id             = 1,
    @subsystem           = N'TSQL',
    @database_name       = N'master',
    @on_success_action   = 1,
    @on_fail_action      = 2,
    @retry_attempts      = 2,
    @retry_interval      = 5,
    @command             = N'
-- Έλεγχος έκδοσης SQL Server
IF CAST(SERVERPROPERTY(''ProductMajorVersion'') AS INT) < 13
BEGIN
    RAISERROR(N''SQL Server 2016+ απαιτείται για backup σε Azure Blob Storage με striping.'', 16, 1);
    RETURN;
END

-- =============================================================================
-- *** ΑΛΛΑΞΤΕ ΤΟ URL ΠΑΡΑΚΑΤΩ ΜΕ ΤΟ ΔΙΚΟ ΣΑΣ AZURE BLOB STORAGE URL ***
-- =============================================================================
DECLARE @BaseURL         NVARCHAR(500) = N''https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER'';
-- =============================================================================

DECLARE @ServerName      NVARCHAR(128) = CAST(SERVERPROPERTY(''ServerName'') AS NVARCHAR(128));
DECLARE @DateSuffix      NVARCHAR(50)  = FORMAT(GETDATE(), ''yyyy-MM-dd_HHmmss'');
DECLARE @MaxStripeSizeGB INT           = 195;
DECLARE @MaxStripes      INT           = 64;
DECLARE @MaxTransferSize INT           = 4194304;
DECLARE @BlockSize       INT           = 65536;

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
WHERE d.name NOT IN (''tempdb'', ''model'')
  AND d.state = 0
GROUP BY d.name, d.recovery_model_desc;

IF EXISTS (SELECT 1 FROM #DBInfo WHERE SizeGB > (@MaxStripeSizeGB * @MaxStripes))
BEGIN
    PRINT N''ΣΦΑΛΜΑ: Βάσεις υπερβαίνουν το μέγιστο μέγεθος backup (195 GB x 64 stripes).'';
END

DECLARE @DBName        NVARCHAR(256);
DECLARE @SizeGB        DECIMAL(10,2);
DECLARE @Stripes       INT;
DECLARE @RecoveryModel NVARCHAR(60);
DECLARE @SQL           NVARCHAR(MAX);
DECLARE @i             INT;
DECLARE @Q             CHAR(1) = CHAR(39); -- Single quote για χρήση μέσα στο dynamic SQL

DECLARE db_cursor CURSOR FOR
    SELECT DatabaseName, SizeGB, NumberOfStripes, RecoveryModel 
    FROM #DBInfo 
    ORDER BY SizeGB DESC;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DBName, @SizeGB, @Stripes, @RecoveryModel;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @RecoveryModel = N''FULL''
    BEGIN
        PRINT N''-- ΠΡΟΣΟΧΗ: ['' + @DBName + N''] σε FULL recovery model.'';
    END

    PRINT N''-- Βάση: '' + @DBName + N'' | Μέγεθος: '' + CAST(@SizeGB AS NVARCHAR(20))
        + N'' GB | Stripes: '' + CAST(@Stripes AS NVARCHAR(10))
        + N'' | Recovery: '' + @RecoveryModel;

    SET @SQL = N''BACKUP DATABASE '' + QUOTENAME(@DBName) + N'' TO '' + CHAR(13) + CHAR(10);

    IF @Stripes = 1
    BEGIN
        SET @SQL = @SQL + N''URL = N'' + @Q + @BaseURL + N''/''
            + @ServerName + N''_'' + @DBName + N''_'' + @DateSuffix + N''.bak'' + @Q + CHAR(13) + CHAR(10);
    END
    ELSE
    BEGIN
        SET @i = 1;
        WHILE @i <= @Stripes
        BEGIN
            SET @SQL = @SQL + N''URL = N'' + @Q + @BaseURL + N''/''
                + @ServerName + N''_'' + @DBName + N''_'' + @DateSuffix + N''_'' + CAST(@i AS NVARCHAR(10)) + N''.bak'' + @Q;
            IF @i < @Stripes
                SET @SQL = @SQL + N'','' + CHAR(13) + CHAR(10);
            ELSE
                SET @SQL = @SQL + CHAR(13) + CHAR(10);
            SET @i = @i + 1;
        END
    END

    SET @SQL = @SQL + N''WITH NOFORMAT, NOINIT, '' + CHAR(13) + CHAR(10)
        + N''NAME = N'' + @Q + @DBName + N''-Full Database Backup'' + @Q + N'', '' + CHAR(13) + CHAR(10)
        + N''NOSKIP, NOREWIND, NOUNLOAD, COMPRESSION, '' + CHAR(13) + CHAR(10)
        + N''MAXTRANSFERSIZE = '' + CAST(@MaxTransferSize AS NVARCHAR(20)) + N'', ''
        + N''BLOCKSIZE = '' + CAST(@BlockSize AS NVARCHAR(20)) + N'', '' + CHAR(13) + CHAR(10)
        + N''STATS = 1;'';

    PRINT @SQL;
    EXEC(@SQL);

    FETCH NEXT FROM db_cursor INTO @DBName, @SizeGB, @Stripes, @RecoveryModel;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;
DROP TABLE #DBInfo;
';

-- =============================================================================
-- Schedule: Καθημερινά στη 01:00
-- =============================================================================
EXEC msdb.dbo.sp_add_jobschedule 
    @job_id              = @jobId,
    @name                = N'Nightly 01:00 Schedule',
    @enabled             = 0,        -- Disabled by default, remember to enable it after check. 
    @freq_type           = 4,        -- Daily
    @freq_interval       = 1,        -- Κάθε 1 ημέρα
    @freq_subday_type    = 1,        -- Σε συγκεκριμένη ώρα
    @active_start_time   = 10000;    -- 01:00:00 (HHMMSS format)

-- =============================================================================
-- Ορισμός Target Server (τοπικός)
-- =============================================================================
EXEC msdb.dbo.sp_add_jobserver 
    @job_id      = @jobId,
    @server_name = N'(local)';

PRINT N'';
PRINT N'Job δημιουργήθηκε: "Nightly Azure Blob Backup - All Databases with Striping"';
PRINT N'Schedule: Καθημερινά στη 01:00';
PRINT N'';
PRINT N'ΠΡΙΝ ΕΝΕΡΓΟΠΟΙΗΣΕΤΕ ΤΟ JOB:';
PRINT N'  1) Αντικαταστήστε YOUR_STORAGE_ACCOUNT και YOUR_CONTAINER στο Step';
PRINT N'  2) Βεβαιωθείτε ότι υπάρχει credential για αυτό το URL';
GO

-- =============================================================================
-- CREDENTIAL (ΜΟΝΟ ΜΙΑ ΦΟΡΑ - αφαιρέστε τα σχόλια):
-- =============================================================================
-- CREATE CREDENTIAL [https://YOUR_STORAGE_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER]
--     WITH IDENTITY = N'Shared Access Signature',
--     SECRET = N'sp=...'   -- SAS token χωρίς το αρχικό '?'
-- GO
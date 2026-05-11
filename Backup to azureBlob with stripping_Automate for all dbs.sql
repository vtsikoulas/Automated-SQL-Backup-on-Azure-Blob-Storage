-- Tsikoulas Vasilis For Entersoftone 2026-05 - vtsikoulas@impact.gr
-- Automated Azure Blob Storage backup script with striping for databases > 195GB
-- Max stripe size: 195 GB (Azure block blob limit)
-- Max stripes: 64 (SQL Server limit)
-- Uncomment line 140 to enable automatic execution of generated backup commands.
-- File naming format: ServerName_DatabaseName_Date_Time.bak


-- Uncomment and run once Δημιουργία Credential για το Azure Blob Storage, με όνομα το URL του container και τύπο ταυτοποίησης Shared Access Signature (SAS) και το κλειδί που δημιουργήσαμε στο Azure Portal.
--USE [master]
--GO
--CREATE CREDENTIAL [https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups] WITH IDENTITY = N'Shared Access Signature', SECRET = N'123'  --Χωρίς το "?" πρέπει να ξεκινάει με "sp=..." 
--GO



-- Check SQL Server version (Backup to URL with block blobs requires SQL Server 2016+)
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 13
BEGIN
    PRINT N'** ERROR: SQL Server version ' + CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)) 
        + N' detected. Backup to URL with block blobs and striping requires SQL Server 2016 (v13) or later. **';
    PRINT N'** Script execution aborted. **';
    RETURN;
END

DECLARE @BaseURL NVARCHAR(500) = N'https://vtsikoulasstorage2.blob.core.windows.net/dtabasebackups'; 
DECLARE @ServerName NVARCHAR(128) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));
DECLARE @DateSuffix NVARCHAR(50) = FORMAT(GETDATE(), 'yyyy-MM-dd_HHmmss');
DECLARE @MaxStripeSizeGB INT = 195;
DECLARE @MaxStripes INT = 64;
DECLARE @MaxTransferSize INT = 4194304;
DECLARE @BlockSize INT = 65536;

-- Gather database info
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
WHERE d.name NOT IN ('tempdb', 'model')
  AND d.state = 0 -- ONLINE only
GROUP BY d.name, d.recovery_model_desc;

-- Display database info
SELECT * FROM #DBInfo ORDER BY SizeGB DESC;

-- Warn about max backup size limit
IF EXISTS (SELECT 1 FROM #DBInfo WHERE SizeGB > (@MaxStripeSizeGB * @MaxStripes))
BEGIN
    PRINT N'** ERROR: One or more databases exceed the maximum backup size of ' 
        + CAST(@MaxStripeSizeGB * @MaxStripes AS NVARCHAR(20)) + N' GB (195 GB x 64 stripes). These cannot be backed up to Azure Blob Storage with this method. **';
    PRINT N'';
END

-- Generate backup commands (largest to smallest)
DECLARE @DBName NVARCHAR(256);
DECLARE @SizeGB DECIMAL(10,2);
DECLARE @Stripes INT;
DECLARE @RecoveryModel NVARCHAR(60);
DECLARE @SQL NVARCHAR(MAX);
DECLARE @i INT;

DECLARE db_cursor CURSOR FOR
    SELECT DatabaseName, SizeGB, NumberOfStripes, RecoveryModel 
    FROM #DBInfo 
    ORDER BY SizeGB DESC;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DBName, @SizeGB, @Stripes, @RecoveryModel;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Warning for FULL recovery model
    IF @RecoveryModel = N'FULL'
    BEGIN
        PRINT N'-- ** WARNING: DB [' + @DBName + N'] is in FULL recovery model. '
            + N'Please check your backup strategy and your RPO. **';
    END

    PRINT N'-- Database: ' + @DBName + N' | Size: ' + CAST(@SizeGB AS NVARCHAR(20)) 
        + N' GB | Stripes: ' + CAST(@Stripes AS NVARCHAR(10))
        + N' | Recovery: ' + @RecoveryModel;

    SET @SQL = N'BACKUP DATABASE ' + QUOTENAME(@DBName) + N' TO ' + CHAR(13) + CHAR(10);

    IF @Stripes = 1
    BEGIN
        SET @SQL = @SQL + N'URL = N''' + @BaseURL + N'/' 
            + @ServerName + N'_' + @DBName + N'_' + @DateSuffix + N'.bak''' + CHAR(13) + CHAR(10);
    END
    ELSE
    BEGIN
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

    -- Uncomment to execute automatically:
    -- EXEC(@SQL);

    FETCH NEXT FROM db_cursor INTO @DBName, @SizeGB, @Stripes, @RecoveryModel;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DROP TABLE #DBInfo;
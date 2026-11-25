/* ============================================================================
   QA TEST SQL - CL_DIAG_XREF  /  THP GM incremental
   Spec        : CL_DIAG_XREF_Incr.xlsx
                 - "Target Data Structure Map" TDS.051 - TDS.063  (THP GM rules)
                 - "THP GM" tab                                   (column mapping)
                 - "GM sql" tab                                   (ETL reference sql)
   Platform    : Teradata
   Target      : EDWTBLVIEW.CL_DIAG_XREF
   Sources     : EDWSRCVIEW.TG_CLAIM_DIAG_MR   (BK = SEQ_NUM 1, BF = SEQ_NUM > 1)
                 EDWSRCVIEW.TG_CLAIM_MR        (BJ = ADMIT_DIAG_CODE)
                 EDWWRKVIEW.CL_TG_ALLCLAIM_WRK (claim-level dedup)
                 EDWTBLVIEW.CL_TG_CL_XWLK      (APPL_CL_NBR / APPL_VER_NBR)
                 EDWTBLVIEW.CL_CL_AL + CL_CL   (CL_CL_ID, SRC_CD IN ('TMP','THPP'))
                 EDWTBLVIEW.CL_DIAG_ROLE_TYP   (DIAG_ROLE_TYP_ID, default 0)
                 EDWTBLVIEW.CL_DIAG_TYP        (DIAG_TYP_ID,      default 0)

   HOW TO USE
     Q1  SOURCE SQL  - expected image of CL_DIAG_XREF built from the ODS sources.
     Q2  TARGET SQL  - actual active image of CL_DIAG_XREF for THP GM.
     Q3/Q4/Q5  One self-contained block holding both queries as CTEs:
               Q5 row counts, then Q3 SOURCE MINUS TARGET and
               Q4 TARGET MINUS SOURCE.  Both MINUS legs expect 0 rows.
     Q6  DIAG_SEQ_NBR uniqueness inside a claim version.             Expect 0 rows.
     Q7  Lookups that fell to the default (DIAG_TYP_ID / DIAG_ROLE_TYP_ID = 0).
     Q8  ROW_DEL_IND / ROW_OVLAY_IND profile of the load.
     Q9  Update-history pairing: old row must be 'YY', new row 'NY'. Expect 0 rows.
     Q10 True delete (TDS.062): diag deleted in source must be ROW_DEL_IND='Y'.
     Q11 True delete (TDS.063): admitting diag inherits CL_CL true delete.

   PARAMETERS - set the same values in every query before running
     Claim filter : uncomment the  AND X.APPL_CL_NBR IN (...)  /  CLAIM_NUMBER IN (...)
                    lines to scope a smoke test. Leave commented for a full compare.
     Load date    : &LOAD_DT below is the date the incremental cycle ran; used only
                    by Q7/Q8 to isolate the current cycle.
   ============================================================================ */


/* ============================================================================
   Q1 - SOURCE SQL : expected CL_DIAG_XREF image derived from THP GM sources
   ----------------------------------------------------------------------------
   Note: unlike the "GM sql" tab this query deliberately has NO
         "WHERE NOT EXISTS (... CL_DIAG_XREF ...)" predicate. That predicate is
         the ETL's change-detection filter; for QA we want the full expected
         image so it can be compared row-for-row against the target.
   ============================================================================ */
SELECT  C.APPL_CL_NBR                                         AS APPL_CL_NBR
     ,  C.APPL_VER_NBR                                        AS APPL_VER_NBR
     ,  CL.CL_CL_ID                                           AS CL_CL_ID
     ,  CAST(CL.EDW_PY_MB_K AS DECIMAL(18,0))                 AS EDW_PY_MB_K
     ,  CAST(C.DRV_SEQ_NBR AS SMALLINT)                       AS DIAG_SEQ_NBR
     ,  CAST(TRIM(C.DIAG_CODE) AS VARCHAR(20))                AS APPL_DIAG_TYP_CD
     ,  CAST(C.APPL_DIAG_ROLE_TYP_CD AS VARCHAR(20))          AS APPL_DIAG_ROLE_TYP_CD
     ,  CAST(COALESCE(RTYP.DIAG_ROLE_TYP_ID,0) AS INTEGER)    AS DIAG_ROLE_TYP_ID
     ,  CAST(COALESCE(DTYP.DIAG_TYP_ID,0) AS SMALLINT)        AS DIAG_TYP_ID
     ,  CAST(UPPER(TRIM(C.PRESENT_ON_ADMIT)) AS VARCHAR(20))  AS CL_POA_IND
     ,  CAST(
          CASE UPPER(TRIM(C.PRESENT_ON_ADMIT))
            WHEN 'Y' THEN 'PRESENT AT THE TIME OF INPATIENT ADMISSION'
            WHEN 'N' THEN 'NOT PRESENT AT THE TIME OF INPATIENT ADMISSION'
            WHEN 'U' THEN 'DOCUMENTATION IS INSUFFICIENT TO DETERMINE IF CONDITION IS PRESENT ON ADMISSION'
            WHEN 'W' THEN 'PROVIDER IS UNABLE TO CLINICALLY DETERMINE WHETHER CONDITION WAS PRESENT ON ADMISSION OR NOT'
            WHEN '1' THEN 'EXEMPT FROM POA REPORTING,UNREPORTED/NOT USED.THIS CODE IS THE EQUIVALENT CODE OF A BLANK ON UB-04'
            ELSE 'NA'
          END AS VARCHAR(100))                                AS CL_POA_TXT
/* one row per claim version / derived sequence number */
QUALIFY ROW_NUMBER() OVER (PARTITION BY C.APPL_CL_NBR, C.APPL_VER_NBR, C.DRV_SEQ_NBR
                           ORDER BY DTYP.DIAG_TYP_ID DESC) = 1
FROM (
        /* ---- B : assign DIAG_SEQ_NBR. BK = 1, BJ = 2, BF increments from there ---- */
        SELECT  B.*
             ,  RANK() OVER (PARTITION BY B.APPL_CL_NBR, B.APPL_VER_NBR
                             ORDER BY B.LOAD_ORDER) AS DRV_SEQ_NBR
        FROM (
                SELECT  CASE WHEN A.APPL_DIAG_ROLE_TYP_CD = 'BK' THEN 1
                             WHEN A.APPL_DIAG_ROLE_TYP_CD = 'BJ' THEN 2
                             ELSE A.SEQ_NUM + 10
                        END AS LOAD_ORDER
                     ,  A.*
                FROM (
                        /* ---- BK (principal, SEQ_NUM = 1) and BF (all other diags) ---- */
                        SELECT  X.APPL_CL_NBR
                             ,  X.APPL_VER_NBR
                             ,  DIAG.CLAIM_NUMBER
                             ,  DIAG.CLAIM_SUFFIX
                             ,  DIAG.DIAG_CODE
                             ,  DIAG.SEQ_NUM
                             ,  DIAG.PRESENT_ON_ADMIT
                             ,  CASE WHEN DIAG.SEQ_NUM = 1 THEN 'BK'   -- Principal Diagnosis
                                     ELSE 'BF'                         -- Other than BJ/BK/BN/ZZ
                                END AS APPL_DIAG_ROLE_TYP_CD
                        /* multiple DATA_SOURCE rows produce dups - keep latest sys id */
                        QUALIFY RANK() OVER (PARTITION BY X.CLAIM_NUMBER, X.APPL_VER_NBR, DIAG.SEQ_NUM
                                             ORDER BY DIAG.CLAIM_DIAG_SYS_ID DESC) = 1
                        FROM EDWSRCVIEW.TG_CLAIM_DIAG_MR DIAG
                        INNER JOIN EDWWRKVIEW.CL_TG_ALLCLAIM_WRK ALLCLAIM
                           ON ALLCLAIM.CLAIM_SYS_ID = DIAG.CLAIM_SYS_ID
                        INNER JOIN EDWTBLVIEW.CL_TG_CL_XWLK X
                           ON DIAG.CLAIM_NUMBER  = X.CLAIM_NUMBER
                          AND DIAG.CLAIM_SUFFIX  = X.CLAIM_SUFFIX
                          AND DIAG.SOURCE_SYS_ID = X.SOURCE_SYS_ID
                          AND COALESCE(DIAG.DTL__CAPXACTION,'N') = 'N'
                        WHERE DIAG.DIAG_CODE IS NOT NULL      -- THP GM tab row 23
                          AND COALESCE(X.ROW_OVLAY_IND || X.ROW_DEL_IND,'A') <> 'YY'
                        --  AND X.APPL_CL_NBR IN ('000173643200TMP')

                        UNION

                        /* ---- BJ (admitting diagnosis, from the claim header) ---- */
                        SELECT  X.APPL_CL_NBR
                             ,  X.APPL_VER_NBR
                             ,  CL1.CLAIM_NUMBER
                             ,  CL1.CLAIM_SUFFIX
                             ,  CL1.ADMIT_DIAG_CODE               AS DIAG_CODE
                             ,  CAST(NULL AS DECIMAL(4,0))        AS SEQ_NUM
                             ,  'U'                               AS PRESENT_ON_ADMIT
                             ,  'BJ'                              AS APPL_DIAG_ROLE_TYP_CD
                        FROM EDWSRCVIEW.TG_CLAIM_MR CL1
                        INNER JOIN EDWWRKVIEW.CL_TG_ALLCLAIM_WRK ALLCLAIM
                           ON ALLCLAIM.CLAIM_SYS_ID = CL1.CLAIM_SYS_ID
                        INNER JOIN EDWTBLVIEW.CL_TG_CL_XWLK X
                           ON CL1.CLAIM_NUMBER  = X.CLAIM_NUMBER
                          AND CL1.CLAIM_SUFFIX  = X.CLAIM_SUFFIX
                          AND CL1.SOURCE_SYS_ID = X.SOURCE_SYS_ID
                          AND COALESCE(CL1.DTL__CAPXACTION,'N') <> 'D'
                        WHERE CL1.ADMIT_DIAG_CODE IS NOT NULL     -- THP GM tab row 16
                          AND COALESCE(X.ROW_OVLAY_IND || X.ROW_DEL_IND,'A') <> 'YY'
                        --  AND X.APPL_CL_NBR IN ('000173643200TMP')
                     ) A
             ) B
     ) C
/* ---- resolve the parent claim row: CL_CL_ID / EDW_PY_MB_K ---- */
INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
   ON CLAL.APPL_CL_NBR = C.APPL_CL_NBR
  AND CLAL.SRC_CD IN ('TMP','THPP')
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CL.EDW_CL_K     = CLAL.EDW_CL_K
  AND CL.APPL_VER_NBR = C.APPL_VER_NBR
  AND COALESCE(CL.ROW_OVLAY_IND || CL.ROW_DEL_IND,'A') <> 'YY'
/* ---- lookup DIAG_ROLE_TYP_ID, default 0 (TDS.057) ---- */
LEFT JOIN EDWTBLVIEW.CL_DIAG_ROLE_TYP RTYP
   ON RTYP.DIAG_ROLE_TYP_CD = C.APPL_DIAG_ROLE_TYP_CD
/* ---- lookup DIAG_TYP_ID, default 0; period-insensitive, newest ICD wins (TDS.058) ---- */
LEFT JOIN (
        SELECT DIAG_TYP_ID, DIAG_TYP_CD, ICD_VER_NBR, DIAG_TYP_FMT_CD
        QUALIFY RANK() OVER (PARTITION BY OREPLACE(TRIM(DIAG_TYP_FMT_CD),'.','')
                             ORDER BY ICD_VER_NBR DESC, DIAG_TYP_ID DESC) = 1
        FROM EDWTBLVIEW.CL_DIAG_TYP
     ) DTYP
   ON OREPLACE(TRIM(C.DIAG_CODE),'.','') = OREPLACE(TRIM(DTYP.DIAG_TYP_FMT_CD),'.','')
ORDER BY 1,2,5
;


/* ============================================================================
   Q2 - TARGET SQL : actual active CL_DIAG_XREF image for THP GM
   ----------------------------------------------------------------------------
   Active = not an update-delete ('YY') and not a true delete (ROW_DEL_IND='Y'),
   at every level: CL_DIAG_XREF, CL_CL and CL_TG_CL_XWLK.
   ============================================================================ */
SELECT  CLAL.APPL_CL_NBR                                      AS APPL_CL_NBR
     ,  CL.APPL_VER_NBR                                       AS APPL_VER_NBR
     ,  DIAGX.CL_CL_ID                                        AS CL_CL_ID
     ,  CAST(DIAGX.EDW_PY_MB_K AS DECIMAL(18,0))              AS EDW_PY_MB_K
     ,  CAST(DIAGX.DIAG_SEQ_NBR AS SMALLINT)                  AS DIAG_SEQ_NBR
     ,  CAST(TRIM(DIAGX.APPL_DIAG_TYP_CD) AS VARCHAR(20))     AS APPL_DIAG_TYP_CD
     ,  CAST(DIAGX.APPL_DIAG_ROLE_TYP_CD AS VARCHAR(20))      AS APPL_DIAG_ROLE_TYP_CD
     ,  CAST(DIAGX.DIAG_ROLE_TYP_ID AS INTEGER)               AS DIAG_ROLE_TYP_ID
     ,  CAST(DIAGX.DIAG_TYP_ID AS SMALLINT)                   AS DIAG_TYP_ID
     ,  CAST(DIAGX.CL_POA_IND AS VARCHAR(20))                 AS CL_POA_IND
     ,  CAST(DIAGX.CL_POA_TXT AS VARCHAR(100))                AS CL_POA_TXT
FROM EDWTBLVIEW.CL_DIAG_XREF DIAGX
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CL.CL_CL_ID = DIAGX.CL_CL_ID
INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
   ON CLAL.EDW_CL_K = CL.EDW_CL_K
  AND CLAL.SRC_CD IN ('TMP','THPP')
WHERE COALESCE(DIAGX.ROW_OVLAY_IND || DIAGX.ROW_DEL_IND,'A') <> 'YY'
  AND DIAGX.ROW_DEL_IND = 'N'
  AND COALESCE(CL.ROW_OVLAY_IND || CL.ROW_DEL_IND,'A') <> 'YY'
  AND CL.ROW_DEL_IND = 'N'
--  AND CLAL.APPL_CL_NBR IN ('000173643200TMP')
ORDER BY 1,2,5
;


/* ============================================================================
   Q3 / Q4 / Q5 - RECONCILIATION  (self-contained: SRC and TGT inlined as CTEs)

   Run Q5 first. If the counts match, still run Q3/Q4 - equal counts do not
   prove equal content. Both MINUS legs must return 0 rows.
     Q3 leg = in source, not in target  -> missing or mis-transformed rows
     Q4 leg = in target, not in source  -> extra, stale, or not-deleted rows
   ============================================================================ */
WITH SRC AS (
   SELECT  C.APPL_CL_NBR                                         AS APPL_CL_NBR
        ,  C.APPL_VER_NBR                                        AS APPL_VER_NBR
        ,  CL.CL_CL_ID                                           AS CL_CL_ID
        ,  CAST(CL.EDW_PY_MB_K AS DECIMAL(18,0))                 AS EDW_PY_MB_K
        ,  CAST(C.DRV_SEQ_NBR AS SMALLINT)                       AS DIAG_SEQ_NBR
        ,  CAST(TRIM(C.DIAG_CODE) AS VARCHAR(20))                AS APPL_DIAG_TYP_CD
        ,  CAST(C.APPL_DIAG_ROLE_TYP_CD AS VARCHAR(20))          AS APPL_DIAG_ROLE_TYP_CD
        ,  CAST(COALESCE(RTYP.DIAG_ROLE_TYP_ID,0) AS INTEGER)    AS DIAG_ROLE_TYP_ID
        ,  CAST(COALESCE(DTYP.DIAG_TYP_ID,0) AS SMALLINT)        AS DIAG_TYP_ID
        ,  CAST(UPPER(TRIM(C.PRESENT_ON_ADMIT)) AS VARCHAR(20))  AS CL_POA_IND
        ,  CAST(
             CASE UPPER(TRIM(C.PRESENT_ON_ADMIT))
               WHEN 'Y' THEN 'PRESENT AT THE TIME OF INPATIENT ADMISSION'
               WHEN 'N' THEN 'NOT PRESENT AT THE TIME OF INPATIENT ADMISSION'
               WHEN 'U' THEN 'DOCUMENTATION IS INSUFFICIENT TO DETERMINE IF CONDITION IS PRESENT ON ADMISSION'
               WHEN 'W' THEN 'PROVIDER IS UNABLE TO CLINICALLY DETERMINE WHETHER CONDITION WAS PRESENT ON ADMISSION OR NOT'
               WHEN '1' THEN 'EXEMPT FROM POA REPORTING,UNREPORTED/NOT USED.THIS CODE IS THE EQUIVALENT CODE OF A BLANK ON UB-04'
               ELSE 'NA'
             END AS VARCHAR(100))                                AS CL_POA_TXT
   QUALIFY ROW_NUMBER() OVER (PARTITION BY C.APPL_CL_NBR, C.APPL_VER_NBR, C.DRV_SEQ_NBR
                              ORDER BY DTYP.DIAG_TYP_ID DESC) = 1
   FROM (
           SELECT  B.*
                ,  RANK() OVER (PARTITION BY B.APPL_CL_NBR, B.APPL_VER_NBR
                                ORDER BY B.LOAD_ORDER) AS DRV_SEQ_NBR
           FROM (
                   SELECT  CASE WHEN A.APPL_DIAG_ROLE_TYP_CD = 'BK' THEN 1
                                WHEN A.APPL_DIAG_ROLE_TYP_CD = 'BJ' THEN 2
                                ELSE A.SEQ_NUM + 10
                           END AS LOAD_ORDER
                        ,  A.*
                   FROM (
                           SELECT  X.APPL_CL_NBR
                                ,  X.APPL_VER_NBR
                                ,  DIAG.CLAIM_NUMBER
                                ,  DIAG.CLAIM_SUFFIX
                                ,  DIAG.DIAG_CODE
                                ,  DIAG.SEQ_NUM
                                ,  DIAG.PRESENT_ON_ADMIT
                                ,  CASE WHEN DIAG.SEQ_NUM = 1 THEN 'BK'
                                        ELSE 'BF'
                                   END AS APPL_DIAG_ROLE_TYP_CD
                           QUALIFY RANK() OVER (PARTITION BY X.CLAIM_NUMBER, X.APPL_VER_NBR, DIAG.SEQ_NUM
                                                ORDER BY DIAG.CLAIM_DIAG_SYS_ID DESC) = 1
                           FROM EDWSRCVIEW.TG_CLAIM_DIAG_MR DIAG
                           INNER JOIN EDWWRKVIEW.CL_TG_ALLCLAIM_WRK ALLCLAIM
                              ON ALLCLAIM.CLAIM_SYS_ID = DIAG.CLAIM_SYS_ID
                           INNER JOIN EDWTBLVIEW.CL_TG_CL_XWLK X
                              ON DIAG.CLAIM_NUMBER  = X.CLAIM_NUMBER
                             AND DIAG.CLAIM_SUFFIX  = X.CLAIM_SUFFIX
                             AND DIAG.SOURCE_SYS_ID = X.SOURCE_SYS_ID
                             AND COALESCE(DIAG.DTL__CAPXACTION,'N') = 'N'
                           WHERE DIAG.DIAG_CODE IS NOT NULL
                             AND COALESCE(X.ROW_OVLAY_IND || X.ROW_DEL_IND,'A') <> 'YY'
                           --  AND X.APPL_CL_NBR IN ('000173643200TMP')

                           UNION

                           SELECT  X.APPL_CL_NBR
                                ,  X.APPL_VER_NBR
                                ,  CL1.CLAIM_NUMBER
                                ,  CL1.CLAIM_SUFFIX
                                ,  CL1.ADMIT_DIAG_CODE               AS DIAG_CODE
                                ,  CAST(NULL AS DECIMAL(4,0))        AS SEQ_NUM
                                ,  'U'                               AS PRESENT_ON_ADMIT
                                ,  'BJ'                              AS APPL_DIAG_ROLE_TYP_CD
                           FROM EDWSRCVIEW.TG_CLAIM_MR CL1
                           INNER JOIN EDWWRKVIEW.CL_TG_ALLCLAIM_WRK ALLCLAIM
                              ON ALLCLAIM.CLAIM_SYS_ID = CL1.CLAIM_SYS_ID
                           INNER JOIN EDWTBLVIEW.CL_TG_CL_XWLK X
                              ON CL1.CLAIM_NUMBER  = X.CLAIM_NUMBER
                             AND CL1.CLAIM_SUFFIX  = X.CLAIM_SUFFIX
                             AND CL1.SOURCE_SYS_ID = X.SOURCE_SYS_ID
                             AND COALESCE(CL1.DTL__CAPXACTION,'N') <> 'D'
                           WHERE CL1.ADMIT_DIAG_CODE IS NOT NULL
                             AND COALESCE(X.ROW_OVLAY_IND || X.ROW_DEL_IND,'A') <> 'YY'
                           --  AND X.APPL_CL_NBR IN ('000173643200TMP')
                        ) A
                ) B
        ) C
   INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
      ON CLAL.APPL_CL_NBR = C.APPL_CL_NBR
     AND CLAL.SRC_CD IN ('TMP','THPP')
   INNER JOIN EDWTBLVIEW.CL_CL CL
      ON CL.EDW_CL_K     = CLAL.EDW_CL_K
     AND CL.APPL_VER_NBR = C.APPL_VER_NBR
     AND COALESCE(CL.ROW_OVLAY_IND || CL.ROW_DEL_IND,'A') <> 'YY'
   LEFT JOIN EDWTBLVIEW.CL_DIAG_ROLE_TYP RTYP
      ON RTYP.DIAG_ROLE_TYP_CD = C.APPL_DIAG_ROLE_TYP_CD
   LEFT JOIN (
           SELECT DIAG_TYP_ID, DIAG_TYP_CD, ICD_VER_NBR, DIAG_TYP_FMT_CD
           QUALIFY RANK() OVER (PARTITION BY OREPLACE(TRIM(DIAG_TYP_FMT_CD),'.','')
                                ORDER BY ICD_VER_NBR DESC, DIAG_TYP_ID DESC) = 1
           FROM EDWTBLVIEW.CL_DIAG_TYP
        ) DTYP
      ON OREPLACE(TRIM(C.DIAG_CODE),'.','') = OREPLACE(TRIM(DTYP.DIAG_TYP_FMT_CD),'.','')
)
,    TGT AS (
   SELECT  CLAL.APPL_CL_NBR                                      AS APPL_CL_NBR
        ,  CL.APPL_VER_NBR                                       AS APPL_VER_NBR
        ,  DIAGX.CL_CL_ID                                        AS CL_CL_ID
        ,  CAST(DIAGX.EDW_PY_MB_K AS DECIMAL(18,0))              AS EDW_PY_MB_K
        ,  CAST(DIAGX.DIAG_SEQ_NBR AS SMALLINT)                  AS DIAG_SEQ_NBR
        ,  CAST(TRIM(DIAGX.APPL_DIAG_TYP_CD) AS VARCHAR(20))     AS APPL_DIAG_TYP_CD
        ,  CAST(DIAGX.APPL_DIAG_ROLE_TYP_CD AS VARCHAR(20))      AS APPL_DIAG_ROLE_TYP_CD
        ,  CAST(DIAGX.DIAG_ROLE_TYP_ID AS INTEGER)               AS DIAG_ROLE_TYP_ID
        ,  CAST(DIAGX.DIAG_TYP_ID AS SMALLINT)                   AS DIAG_TYP_ID
        ,  CAST(DIAGX.CL_POA_IND AS VARCHAR(20))                 AS CL_POA_IND
        ,  CAST(DIAGX.CL_POA_TXT AS VARCHAR(100))                AS CL_POA_TXT
   FROM EDWTBLVIEW.CL_DIAG_XREF DIAGX
   INNER JOIN EDWTBLVIEW.CL_CL CL
      ON CL.CL_CL_ID = DIAGX.CL_CL_ID
   INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
      ON CLAL.EDW_CL_K = CL.EDW_CL_K
     AND CLAL.SRC_CD IN ('TMP','THPP')
   WHERE COALESCE(DIAGX.ROW_OVLAY_IND || DIAGX.ROW_DEL_IND,'A') <> 'YY'
     AND DIAGX.ROW_DEL_IND = 'N'
     AND COALESCE(CL.ROW_OVLAY_IND || CL.ROW_DEL_IND,'A') <> 'YY'
     AND CL.ROW_DEL_IND = 'N'
   --  AND CLAL.APPL_CL_NBR IN ('000173643200TMP')
)

/* ---- Q5 : row counts. Comment this block out when running Q3/Q4. ---- */
SELECT 'SOURCE' AS SIDE, COUNT(*) AS ROW_CNT, COUNT(DISTINCT APPL_CL_NBR) AS CLM_CNT FROM SRC
UNION ALL
SELECT 'TARGET' AS SIDE, COUNT(*) AS ROW_CNT, COUNT(DISTINCT APPL_CL_NBR) AS CLM_CNT FROM TGT
ORDER BY 1
;

/* ---- Q3 / Q4 : content difference. Re-run the WITH block above with this
        final SELECT instead of the Q5 one. Expect 0 rows. ---- */
/*
SELECT 'SRC_NOT_IN_TGT' AS DIFF_SIDE, D.* FROM (
   SELECT * FROM SRC
   MINUS
   SELECT * FROM TGT
) D
UNION ALL
SELECT 'TGT_NOT_IN_SRC' AS DIFF_SIDE, D.* FROM (
   SELECT * FROM TGT
   MINUS
   SELECT * FROM SRC
) D
ORDER BY 1,2,3,6
;
*/


/* ============================================================================
   Q6 - DIAG_SEQ_NBR must be unique within a claim version, and BK must be 1.
        ("THP GM" tab rows 9/18: load BK first so DIAG_SEQ_NBR is always 1,
         admitting diag is 2, BF increments from there. No duplicates.)
        Expect 0 rows.
   ============================================================================ */
SELECT  CLAL.APPL_CL_NBR
     ,  CL.APPL_VER_NBR
     ,  DIAGX.CL_CL_ID
     ,  DIAGX.DIAG_SEQ_NBR
     ,  COUNT(*)                                   AS DUP_CNT
     ,  MIN(DIAGX.APPL_DIAG_ROLE_TYP_CD)           AS MIN_ROLE_CD
     ,  MAX(DIAGX.APPL_DIAG_ROLE_TYP_CD)           AS MAX_ROLE_CD
FROM EDWTBLVIEW.CL_DIAG_XREF DIAGX
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CL.CL_CL_ID = DIAGX.CL_CL_ID
INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
   ON CLAL.EDW_CL_K = CL.EDW_CL_K
  AND CLAL.SRC_CD IN ('TMP','THPP')
WHERE DIAGX.ROW_DEL_IND = 'N'
  AND COALESCE(DIAGX.ROW_OVLAY_IND || DIAGX.ROW_DEL_IND,'A') <> 'YY'
  AND CL.ROW_DEL_IND = 'N'
GROUP BY 1,2,3,4
HAVING COUNT(*) > 1
    OR (DIAGX.DIAG_SEQ_NBR = 1 AND MAX(DIAGX.APPL_DIAG_ROLE_TYP_CD) <> 'BK')
    OR (DIAGX.DIAG_SEQ_NBR = 2 AND MAX(DIAGX.APPL_DIAG_ROLE_TYP_CD) <> 'BJ')
ORDER BY 1,2,4
;


/* ============================================================================
   Q7 - Lookups that fell through to the default value 0.
        Per spec a default is allowed, so this is a review list, not a failure:
        every row here should be explainable by a diag code that genuinely does
        not exist in CL_DIAG_TYP (TDS.058) / CL_DIAG_ROLE_TYP (TDS.057).
   ============================================================================ */
SELECT  DIAGX.APPL_DIAG_TYP_CD
     ,  DIAGX.APPL_DIAG_ROLE_TYP_CD
     ,  DIAGX.DIAG_TYP_ID
     ,  DIAGX.DIAG_ROLE_TYP_ID
     ,  COUNT(*) AS ROW_CNT
FROM EDWTBLVIEW.CL_DIAG_XREF DIAGX
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CL.CL_CL_ID = DIAGX.CL_CL_ID
INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
   ON CLAL.EDW_CL_K = CL.EDW_CL_K
  AND CLAL.SRC_CD IN ('TMP','THPP')
WHERE (DIAGX.DIAG_TYP_ID = 0 OR DIAGX.DIAG_ROLE_TYP_ID = 0)
  AND DIAGX.ROW_DEL_IND = 'N'
  AND DIAGX.EDW_CREAT_DT >= DATE '&LOAD_DT'
GROUP BY 1,2,3,4
ORDER BY 5 DESC
;


/* ============================================================================
   Q8 - Load profile by ROW_DEL_IND / ROW_OVLAY_IND for the current cycle.
        Expected combinations ("THP GM" tab rows 37/38):
          N / N  insert of a brand new diag row
          N / Y  new version of an updated diag row
          Y / Y  superseded (update-delete) prior version
          Y / N  true delete  (TDS.062 / TDS.063)
        Any other combination is a defect.
   ============================================================================ */
SELECT  DIAGX.ROW_DEL_IND
     ,  DIAGX.ROW_OVLAY_IND
     ,  CAST(DIAGX.EDW_CREAT_DT AS DATE) AS EDW_CREAT_DT
     ,  CAST(DIAGX.EDW_UPDT_DT  AS DATE) AS EDW_UPDT_DT
     ,  COUNT(*) AS ROW_CNT
FROM EDWTBLVIEW.CL_DIAG_XREF DIAGX
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CL.CL_CL_ID = DIAGX.CL_CL_ID
INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
   ON CLAL.EDW_CL_K = CL.EDW_CL_K
  AND CLAL.SRC_CD IN ('TMP','THPP')
WHERE COALESCE(DIAGX.EDW_UPDT_DT, DIAGX.EDW_CREAT_DT) >= DATE '&LOAD_DT'
GROUP BY 1,2,3,4
ORDER BY 2,1,4
;


/* ============================================================================
   Q9 - Update-history pairing (TDS.060).
        When a diag row is updated the ETL must leave exactly one superseded
        row ('Y'/'Y') and insert exactly one active row ('N'/'Y') for the same
        CL_CL_ID + DIAG_SEQ_NBR. Rows listed here break that invariant:
        an overlay group with no active row, or more than one active row.
        Expect 0 rows.
   ============================================================================ */
SELECT  DIAGX.CL_CL_ID
     ,  DIAGX.DIAG_SEQ_NBR
     ,  SUM(CASE WHEN DIAGX.ROW_OVLAY_IND = 'Y' AND DIAGX.ROW_DEL_IND = 'Y' THEN 1 ELSE 0 END) AS SUPERSEDED_CNT
     ,  SUM(CASE WHEN DIAGX.ROW_OVLAY_IND = 'Y' AND DIAGX.ROW_DEL_IND = 'N' THEN 1 ELSE 0 END) AS ACTIVE_OVLAY_CNT
     ,  SUM(CASE WHEN DIAGX.ROW_DEL_IND = 'N' THEN 1 ELSE 0 END)                               AS ACTIVE_CNT
FROM EDWTBLVIEW.CL_DIAG_XREF DIAGX
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CL.CL_CL_ID = DIAGX.CL_CL_ID
INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
   ON CLAL.EDW_CL_K = CL.EDW_CL_K
  AND CLAL.SRC_CD IN ('TMP','THPP')
GROUP BY 1,2
HAVING SUM(CASE WHEN DIAGX.ROW_OVLAY_IND = 'Y' AND DIAGX.ROW_DEL_IND = 'Y' THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN DIAGX.ROW_DEL_IND = 'N' THEN 1 ELSE 0 END) <> 1
ORDER BY 1,2
;


/* ============================================================================
   Q10 - TRUE DELETE, non-admitting diag (TDS.062).
         A diag row flagged DTL__CAPXACTION = 'D' in TG_CLAIM_DIAG_MR, with no
         surviving non-'D' row for the same key, must carry ROW_DEL_IND = 'Y'
         in CL_DIAG_XREF. Rows returned here were NOT logically deleted.
         Expect 0 rows.
   ============================================================================ */
SELECT  DIAGX.CL_DIAG_XREF_ID
     ,  X.CLAIM_NUMBER
     ,  X.CLAIM_SUFFIX
     ,  X.APPL_CL_NBR
     ,  X.APPL_VER_NBR
     ,  DIAGX.DIAG_SEQ_NBR
     ,  DIAGX.APPL_DIAG_TYP_CD
     ,  DIAGX.ROW_DEL_IND
     ,  DIAGX.ROW_OVLAY_IND
FROM EDWTBLVIEW.CL_CL_AL CLAL
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CLAL.EDW_CL_K = CL.EDW_CL_K
  AND CLAL.SRC_CD IN ('TMP','THPP')
INNER JOIN EDWTBLVIEW.CL_TG_CL_XWLK X
   ON X.APPL_CL_NBR  = CLAL.APPL_CL_NBR
  AND X.APPL_VER_NBR = CL.APPL_VER_NBR
INNER JOIN EDWTBLVIEW.CL_DIAG_XREF DIAGX
   ON CL.CL_CL_ID = DIAGX.CL_CL_ID
  AND DIAGX.APPL_DIAG_ROLE_TYP_CD <> 'BJ'        -- admitting diag handled by Q11
INNER JOIN EDWSRCVIEW.TG_CLAIM_DIAG_MR DIAG
   ON X.CLAIM_NUMBER  = DIAG.CLAIM_NUMBER
  AND X.CLAIM_SUFFIX  = DIAG.CLAIM_SUFFIX
  AND X.SOURCE_SYS_ID = DIAG.SOURCE_SYS_ID
  AND TRIM(DIAGX.APPL_DIAG_TYP_CD) = TRIM(DIAG.DIAG_CODE)
  AND DIAGX.DIAG_SEQ_NBR = CASE WHEN DIAG.SEQ_NUM = 1 THEN 1
                                ELSE DIAG.SEQ_NUM + 2       -- see NOTE below
                           END
  AND COALESCE(DIAG.DTL__CAPXACTION,'N') = 'D'
WHERE X.ROW_DEL_IND     = 'N'
  AND CL.ROW_DEL_IND    = 'N'
  AND DIAGX.ROW_DEL_IND = 'N'                    -- <-- should have been 'Y'
  AND NOT EXISTS (
        SELECT 1
        FROM EDWSRCVIEW.TG_CLAIM_DIAG_MR DIAG1
        WHERE DIAG1.CLAIM_NUMBER  = DIAG.CLAIM_NUMBER
          AND DIAG1.CLAIM_SUFFIX  = DIAG.CLAIM_SUFFIX
          AND DIAG1.DIAG_CODE     = DIAG.DIAG_CODE
          AND DIAG1.SEQ_NUM       = DIAG.SEQ_NUM
          AND DIAG1.SOURCE_SYS_ID = DIAG.SOURCE_SYS_ID
          AND COALESCE(DIAG1.DTL__CAPXACTION,'N') <> 'D'
      )
ORDER BY 2,3,6
;
/* NOTE on the DIAG_SEQ_NBR expression above.
   TDS.062 specifies  CASE WHEN SEQ_NUM = 1 THEN 1 ELSE SEQ_NUM + 2 END  and this
   query reproduces the spec verbatim so the test matches the documented rule.
   Be aware it does not agree with the derived DRV_SEQ_NBR for every claim:
   DRV_SEQ_NBR is a dense RANK over LOAD_ORDER (BK=1, BJ=2, BF=SEQ_NUM+10), so a
   GM claim with SEQ_NUM starting at 1 lands BF at SEQ_NUM + 1 - not + 2 - and
   when the claim has no ADMIT_DIAG_CODE there is no BJ at all, shifting every BF
   down by one more. The '+2' offset is the THP CM convention (CM SEQ_NUM starts
   at 0). Confirm the intended offset with the data modeler before signing off;
   if the derived rank is authoritative, join on
     DIAGX.DIAG_SEQ_NBR = <DRV_SEQ_NBR from Q1 for the same claim/diag>
   instead of the static CASE. */


/* ============================================================================
   Q11 - TRUE DELETE, admitting diag (TDS.063).
          The admitting diag row inherits the true delete from CL_CL: when CL_CL
          is ROW_DEL_IND='Y' / ROW_OVLAY_IND='N', its 'BJ' CL_DIAG_XREF row must
          also be ROW_DEL_IND='Y'. Expect 0 rows.
   ============================================================================ */
SELECT  DIAGX.CL_DIAG_XREF_ID
     ,  CLAL.APPL_CL_NBR
     ,  CL.APPL_VER_NBR
     ,  DIAGX.DIAG_SEQ_NBR
     ,  DIAGX.APPL_DIAG_TYP_CD
     ,  DIAGX.ROW_DEL_IND
     ,  DIAGX.ROW_OVLAY_IND
FROM EDWTBLVIEW.CL_CL_AL CLAL
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CLAL.EDW_CL_K = CL.EDW_CL_K
  AND CLAL.SRC_CD IN ('TMP','THPP')
INNER JOIN EDWTBLVIEW.CL_TG_CL_XWLK X
   ON X.APPL_CL_NBR  = CLAL.APPL_CL_NBR
  AND X.APPL_VER_NBR = CL.APPL_VER_NBR
INNER JOIN EDWTBLVIEW.CL_DIAG_XREF DIAGX
   ON CL.CL_CL_ID = DIAGX.CL_CL_ID
  AND DIAGX.APPL_DIAG_ROLE_TYP_CD = 'BJ'
WHERE CL.ROW_DEL_IND    = 'Y'
  AND CL.ROW_OVLAY_IND  = 'N'
  AND DIAGX.ROW_DEL_IND = 'N'                    -- <-- should have been 'Y'
ORDER BY 2,3,4
;

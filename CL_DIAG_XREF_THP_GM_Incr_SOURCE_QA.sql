/* ============================================================================
   SOURCE SQL  -  QA expected image of CL_DIAG_XREF   (THP GM, incremental)

   Spec      : CL_DIAG_XREF_Incr.xlsx
               "Target Data Structure Map"  TDS.051 - TDS.063   (THP GM rules)
               "THP GM" tab                                     (column mapping)
               "GM sql" tab                                      (ETL reference sql)
   Platform  : Teradata
   Target    : EDWTBLVIEW.CL_DIAG_XREF
   Pairs with: CL_DIAG_XREF_THP_GM_Incr_TARGET_QA.sql
               Identical 11-column projection, same order, same data types, so
                   <SOURCE SQL>  MINUS  <TARGET SQL>      -> expect 0 rows
                   <TARGET SQL>  MINUS  <SOURCE SQL>      -> expect 0 rows
               Run both legs. Equal row counts do not prove equal content.

   WHAT THIS QUERY IS
     The row image CL_DIAG_XREF *should* hold for THP GM claims, rebuilt from
     the ODS sources:
       EDWSRCVIEW.TG_CLAIM_DIAG_MR    BK (SEQ_NUM = 1) and BF (all other diags)
       EDWSRCVIEW.TG_CLAIM_MR         BJ  (ADMIT_DIAG_CODE, admitting diagnosis)
       EDWWRKVIEW.CL_TG_ALLCLAIM_WRK  claim-level dedup                 TDS.052
       EDWTBLVIEW.CL_TG_CL_XWLK       APPL_CL_NBR / APPL_VER_NBR        TDS.053
       EDWTBLVIEW.CL_CL_AL + CL_CL    CL_CL_ID / EDW_PY_MB_K      TDS.055/056
       EDWTBLVIEW.CL_DIAG_ROLE_TYP    DIAG_ROLE_TYP_ID, default 0       TDS.057
       EDWTBLVIEW.CL_DIAG_TYP         DIAG_TYP_ID,      default 0       TDS.058

   DELIBERATE DIFFERENCES FROM THE "GM sql" TAB
     1. No  WHERE NOT EXISTS (... CL_DIAG_XREF ...)  predicate. In the ETL that
        predicate is change detection (TDS.060) - it suppresses unchanged rows.
        For QA we want the complete expected image to compare row-for-row.
     2. Dedup tie-break drops  DIAGX.CL_DIAG_XREF_ID DESC  (no target reference
        here) and uses TRIM(C.DIAG_CODE) instead, so the result is deterministic.
     3. Adds  ROW_DEL_IND = 'N'  on CL_CL and CL_TG_CL_XWLK. The spec only states
        <> 'YY' (TDS.061), but the TARGET query must exclude true-deleted rows,
        so the source side has to exclude them too or every true delete shows up
        as a false SRC_NOT_IN_TGT difference.

   PARAMETERS
     Claim scope : uncomment the two  AND X.APPL_CL_NBR IN (...)  lines for a
                   smoke test on named claims. Leave commented for a full compare.
                   Keep both legs in sync - BK/BF and BJ must use the same list.
     Data types  : the CASTs make both sides MINUS-compatible. If local DDL for
                   APPL_VER_NBR / CL_CL_ID differs, change the CAST in *both*
                   files together.

   KNOWN CAVEATS - read before raising a defect
     a. CL_POA_TXT is compared as literal text. The "THP GM" tab spells the '1'
        case two ways ("...BLANK ON UB-04" in row 15, "...BLANK ON THE UB-04" in
        row 31) and wraps the 'U'/'W' text across lines. This query uses the
        single-space form below. A diff that is only whitespace or THE/no-THE is
        a spec ambiguity, not an ETL bug - confirm the loaded form with the data
        modeler, then align this CASE to it.
     b. The BK/BF leg keeps only  COALESCE(DTL__CAPXACTION,'N') = 'N'  per
        TDS.053. A diag row sitting at 'U' in the ODS is therefore absent from
        this expected image while the previously loaded row is still active in
        the target, which surfaces as TGT_NOT_IN_SRC. That is the documented
        rule, not a query defect.
   ============================================================================ */

SELECT  CAST(C.APPL_CL_NBR AS VARCHAR(50))                    AS APPL_CL_NBR
     ,  CAST(C.APPL_VER_NBR AS INTEGER)                       AS APPL_VER_NBR
     ,  CAST(CL.CL_CL_ID AS INTEGER)                          AS CL_CL_ID
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

/* one row per claim version / derived sequence number.
   "GM sql" tab, top of query: newest ICD wins when a diag code resolves to more
   than one CL_DIAG_TYP row. */
QUALIFY ROW_NUMBER() OVER (PARTITION BY C.APPL_CL_NBR, C.APPL_VER_NBR, C.DRV_SEQ_NBR
                           ORDER BY DTYP.DIAG_TYP_ID DESC, TRIM(C.DIAG_CODE)) = 1

FROM (
        /* ---- C : derive DIAG_SEQ_NBR.  BK -> 1, BJ -> 2, BF increments from
                there ("THP GM" tab rows 9 / 18 / 26, TDS.051) ---- */
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
                        /* ---- BK (principal, SEQ_NUM = 1) + BF (everything else)
                                TDS.051 / TDS.052 / TDS.053 ---- */
                        SELECT  X.APPL_CL_NBR
                             ,  X.APPL_VER_NBR
                             ,  DIAG.CLAIM_NUMBER
                             ,  DIAG.CLAIM_SUFFIX
                             ,  DIAG.DIAG_CODE
                             ,  DIAG.SEQ_NUM
                             ,  DIAG.PRESENT_ON_ADMIT
                             ,  CASE WHEN DIAG.SEQ_NUM = 1 THEN 'BK'  -- Principal Diagnosis
                                     ELSE 'BF'                       -- other than BJ/BK/BN/ZZ
                                END AS APPL_DIAG_ROLE_TYP_CD
                        /* multiple DATA_SOURCE rows create dups - keep the latest
                           CLAIM_DIAG_SYS_ID (TDS.051, change control 2025-08-05) */
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
                        WHERE DIAG.DIAG_CODE IS NOT NULL   -- "THP GM" tab row 23
                          AND COALESCE(X.ROW_OVLAY_IND || X.ROW_DEL_IND,'A') <> 'YY'
                          AND X.ROW_DEL_IND = 'N'
                        --  AND X.APPL_CL_NBR IN ('000173643200TMP')

                        UNION

                        /* ---- BJ (admitting diagnosis, from the claim header)
                                TDS.054, "THP GM" tab rows 16 - 22 ---- */
                        SELECT  X.APPL_CL_NBR
                             ,  X.APPL_VER_NBR
                             ,  CL1.CLAIM_NUMBER
                             ,  CL1.CLAIM_SUFFIX
                             ,  CL1.ADMIT_DIAG_CODE        AS DIAG_CODE
                             ,  CAST(NULL AS DECIMAL(4,0)) AS SEQ_NUM
                             ,  'U'                        AS PRESENT_ON_ADMIT
                             ,  'BJ'                       AS APPL_DIAG_ROLE_TYP_CD
                        FROM EDWSRCVIEW.TG_CLAIM_MR CL1
                        INNER JOIN EDWWRKVIEW.CL_TG_ALLCLAIM_WRK ALLCLAIM
                           ON ALLCLAIM.CLAIM_SYS_ID = CL1.CLAIM_SYS_ID
                        INNER JOIN EDWTBLVIEW.CL_TG_CL_XWLK X
                           ON CL1.CLAIM_NUMBER  = X.CLAIM_NUMBER
                          AND CL1.CLAIM_SUFFIX  = X.CLAIM_SUFFIX
                          AND CL1.SOURCE_SYS_ID = X.SOURCE_SYS_ID
                          AND COALESCE(CL1.DTL__CAPXACTION,'N') <> 'D'
                        WHERE CL1.ADMIT_DIAG_CODE IS NOT NULL  -- "THP GM" tab row 16
                          AND COALESCE(X.ROW_OVLAY_IND || X.ROW_DEL_IND,'A') <> 'YY'
                          AND X.ROW_DEL_IND = 'N'
                        --  AND X.APPL_CL_NBR IN ('000173643200TMP')
                     ) A
             ) B
     ) C

/* ---- parent claim row: EDW_CL_K, then CL_CL_ID / EDW_PY_MB_K
        TDS.055 / TDS.056, "THP GM" tab rows 3 / 34 ---- */
INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
   ON CLAL.APPL_CL_NBR = C.APPL_CL_NBR
  AND CLAL.SRC_CD IN ('TMP','THPP')
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CL.EDW_CL_K     = CLAL.EDW_CL_K
  AND CL.APPL_VER_NBR = C.APPL_VER_NBR
  AND COALESCE(CL.ROW_OVLAY_IND || CL.ROW_DEL_IND,'A') <> 'YY'
  AND CL.ROW_DEL_IND = 'N'        -- admitting-diag true delete inherits this (TDS.063)

/* ---- DIAG_ROLE_TYP_ID, default 0 (TDS.057) ---- */
LEFT JOIN EDWTBLVIEW.CL_DIAG_ROLE_TYP RTYP
   ON RTYP.DIAG_ROLE_TYP_CD = C.APPL_DIAG_ROLE_TYP_CD

/* ---- DIAG_TYP_ID, default 0 (TDS.058).
        Period-insensitive join, newest ICD version wins
        (change control 2025-07-28 and 2026-03-03). ---- */
LEFT JOIN (
        SELECT  DIAG_TYP_ID
             ,  DIAG_TYP_CD
             ,  ICD_VER_NBR
             ,  DIAG_TYP_FMT_CD
        QUALIFY RANK() OVER (PARTITION BY OREPLACE(TRIM(DIAG_TYP_FMT_CD),'.','')
                             ORDER BY ICD_VER_NBR DESC, DIAG_TYP_ID DESC) = 1
        FROM EDWTBLVIEW.CL_DIAG_TYP
     ) DTYP
   ON OREPLACE(TRIM(C.DIAG_CODE),'.','') = OREPLACE(TRIM(DTYP.DIAG_TYP_FMT_CD),'.','')

ORDER BY 1, 2, 5
;

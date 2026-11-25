/* ============================================================================
   TARGET SQL  -  QA actual image of CL_DIAG_XREF   (THP GM, incremental)

   Spec      : CL_DIAG_XREF_Incr.xlsx
               "Target Data Structure Map"  TDS.051 - TDS.063   (THP GM rules)
               "THP GM" tab                 rows 37 / 38 / 39   (ind handling)
               "GM sql" tab, column S                           (target count sql)
   Platform  : Teradata
   Target    : EDWTBLVIEW.CL_DIAG_XREF
   Pairs with: CL_DIAG_XREF_THP_GM_Incr_SOURCE_QA.sql
               Identical 11-column projection, same order, same data types, so
                   <SOURCE SQL>  MINUS  <TARGET SQL>      -> expect 0 rows
                   <TARGET SQL>  MINUS  <SOURCE SQL>      -> expect 0 rows
               Run both legs. Equal row counts do not prove equal content.

   WHAT "ACTIVE" MEANS HERE
     A THP GM diag row counts as current only when it is neither a superseded
     update nor a true delete, at every level of the chain:
       CL_DIAG_XREF   ROW_OVLAY_IND || ROW_DEL_IND <> 'YY'  and ROW_DEL_IND = 'N'
       CL_CL          ROW_OVLAY_IND || ROW_DEL_IND <> 'YY'  and ROW_DEL_IND = 'N'
     The 'YY' test drops the superseded version the ETL leaves behind on an
     update (TDS.060 / TDS.061); ROW_DEL_IND = 'N' drops true deletes
     (TDS.062 non-admitting, TDS.063 admitting-inherits-CL_CL).
     Expected ind combinations after a load, per "THP GM" tab rows 37 / 38:
       N / N  brand new diag row
       N / Y  new version of an updated diag row          <- active
       Y / Y  superseded prior version                    <- excluded
       Y / N  true delete                                 <- excluded
     PEND claims ("THP GM" tab row 39, CL_TG_CL_XWLK.LOAD_OPTN_TXT = 'PEND')
     keep no history: the row is updated in place to 'N' / 'Y', which this filter
     keeps - correct.

   THP GM SCOPE
     CL_CL_AL.SRC_CD IN ('TMP','THPP') is what makes this a THP GM query
     (TDS.055). Without it you pick up every other source feeding CL_DIAG_XREF
     and both MINUS legs will be full of noise.

   PARAMETERS
     Claim scope : uncomment  AND CLAL.APPL_CL_NBR IN (...)  for a smoke test.
                   Use the same claim list as the SOURCE query.
     Data types  : the CASTs make both sides MINUS-compatible. If local DDL for
                   APPL_VER_NBR / CL_CL_ID differs, change the CAST in *both*
                   files together.
   ============================================================================ */

SELECT  CAST(CLAL.APPL_CL_NBR AS VARCHAR(50))                 AS APPL_CL_NBR
     ,  CAST(CL.APPL_VER_NBR AS INTEGER)                      AS APPL_VER_NBR
     ,  CAST(DIAGX.CL_CL_ID AS INTEGER)                       AS CL_CL_ID
     ,  CAST(DIAGX.EDW_PY_MB_K AS DECIMAL(18,0))              AS EDW_PY_MB_K
     ,  CAST(DIAGX.DIAG_SEQ_NBR AS SMALLINT)                  AS DIAG_SEQ_NBR
     ,  CAST(TRIM(DIAGX.APPL_DIAG_TYP_CD) AS VARCHAR(20))     AS APPL_DIAG_TYP_CD
     ,  CAST(DIAGX.APPL_DIAG_ROLE_TYP_CD AS VARCHAR(20))      AS APPL_DIAG_ROLE_TYP_CD
     ,  CAST(DIAGX.DIAG_ROLE_TYP_ID AS INTEGER)               AS DIAG_ROLE_TYP_ID
     ,  CAST(DIAGX.DIAG_TYP_ID AS SMALLINT)                   AS DIAG_TYP_ID
     ,  CAST(DIAGX.CL_POA_IND AS VARCHAR(20))                 AS CL_POA_IND
     ,  CAST(DIAGX.CL_POA_TXT AS VARCHAR(100))                AS CL_POA_TXT

FROM EDWTBLVIEW.CL_DIAG_XREF DIAGX
/* ---- CL_DIAG_XREF hangs off CL_CL; APPL_CL_NBR / APPL_VER_NBR only become
        visible through CL_CL + CL_CL_AL (TDS.059) ---- */
INNER JOIN EDWTBLVIEW.CL_CL CL
   ON CL.CL_CL_ID = DIAGX.CL_CL_ID
INNER JOIN EDWTBLVIEW.CL_CL_AL CLAL
   ON CLAL.EDW_CL_K = CL.EDW_CL_K
  AND CLAL.SRC_CD IN ('TMP','THPP')          -- THP GM only (TDS.055)

WHERE COALESCE(DIAGX.ROW_OVLAY_IND || DIAGX.ROW_DEL_IND,'A') <> 'YY'
  AND DIAGX.ROW_DEL_IND = 'N'
  AND COALESCE(CL.ROW_OVLAY_IND || CL.ROW_DEL_IND,'A') <> 'YY'
  AND CL.ROW_DEL_IND = 'N'
--  AND CLAL.APPL_CL_NBR IN ('000173643200TMP')

ORDER BY 1, 2, 5
;


/* ============================================================================
   HOW TO RECONCILE THE TWO FILES

   1. Counts first - cheap sanity check, run each query wrapped in
          SELECT COUNT(*), COUNT(DISTINCT APPL_CL_NBR) FROM ( <query minus the
          ORDER BY> ) D;
      Unequal counts mean rows are missing or extra. Equal counts prove nothing
      about content, so always continue to step 2.

   2. Content, both directions. Paste the SOURCE query body and this TARGET
      query body into the two slots below, dropping their trailing ORDER BY and
      semicolon:

        SELECT 'SRC_NOT_IN_TGT' AS DIFF_SIDE, D.* FROM (
           < SOURCE query body >
           MINUS
           < TARGET query body >
        ) D
        UNION ALL
        SELECT 'TGT_NOT_IN_SRC' AS DIFF_SIDE, D.* FROM (
           < TARGET query body >
           MINUS
           < SOURCE query body >
        ) D
        ORDER BY 1,2,3,6
        ;

      SRC_NOT_IN_TGT -> row missing from the target, or a transform is wrong
                        (DIAG_SEQ_NBR, lookup id, POA derivation)
      TGT_NOT_IN_SRC -> extra row, stale row, or a delete the ETL did not apply

   3. A single mis-transformed row shows up once on each side with the same
      key. Sort by APPL_CL_NBR / APPL_VER_NBR / DIAG_SEQ_NBR and compare the
      pair column by column to find which attribute moved.

   An already-assembled version of step 2, plus the rule-level checks
   (DIAG_SEQ_NBR uniqueness, default-0 lookups, ind profile, update-history
   pairing, both true-delete rules), is in
   CL_DIAG_XREF_THP_GM_Incr_QA.sql  Q3 - Q11.
   ============================================================================ */

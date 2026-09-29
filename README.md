# APIS-1116 verification

Checks the CAS schema-info sub-type 21 (`CCI_SCH_SCHEMAS`) on four engine branches in parallel,
in the CI build image `cubridci/cubridci:build_rl8.10`.

| job | checks |
|---|---|
| verify | the unpatched build (the probe fails with -10015, answers of sub-types 1-20, log names), then the patch: probe, sub-types 1-20 unchanged, log names, leak, six mutants, schema TCs, results that take several FETCHes |
| ctp | the JDBC suite with the old driver and TCs on the unpatched build, then with the new ones on the patch, compared by failing case |

A push to this branch starts a run. "Re-run all jobs" takes the latest commit of each branch again.
The branches and their pinned bases are in `.github/workflows/apis1116-verify.yml`.

The secret `TC_REPO_TOKEN` must read the contents of `Srltas/cubrid-testcases-private`.

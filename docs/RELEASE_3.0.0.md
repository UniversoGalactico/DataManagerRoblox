# DataManager 3.0.0

First stable release of the generic v3 profile API. MIT; no runtime dependencies. Install the ModuleScript and read the README before use.

**Breaking change:** use a new store. Do not mix older writers with v3.

Evidence: 25 regression suites at three optimization levels; external finite audit on rc.3 (324,810 checks, including repeated inputs and numeric-oracle checks); maintainer reported 9/9 Studio smoke checks using actual DataStore API access in an empty test experience. The final module changes only its version string. Two live servers, heavy load and prolonged service outages remain unverified.

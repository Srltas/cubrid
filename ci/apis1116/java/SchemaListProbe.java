import java.lang.reflect.Field;
import java.sql.*;
import java.util.*;
import cubrid.jdbc.jci.*;

/*
 * End-to-end checks for the CAS schema-info sub-type 21 (schema names).
 *
 *   SchemaListProbe <port> <db>                 functional checks, exit code = number of failures
 *   SchemaListProbe <port> <db> loop <type> <n> n x (schema info, fetch every row, close)
 *   SchemaListProbe <port> <db> dump            answers of sub-types 1-20 on one fixture, to diff servers
 *   SchemaListProbe <port> <db> send <type> <arg1>   one request, no DDL, to read what the SQL log prints
 *
 * Needs a driver whose USchType.SCH_MAX lets 21 and 22 through.
 */
public class SchemaListProbe {
    static final int SCH_CLASS = 1;
    static final int SCH_SCHEMA = 21;
    static final byte PATTERN = 1; /* CCI_CLASS_NAME_PATTERN_MATCH */
    static final byte EXACT = 0;
    static final String SCHEMATA =
            "select schema_name from information_schema.schemata order by schema_name";

    static String url;
    static Connection dbaConn;
    static int failures = 0;

    interface Check {
        void run() throws Exception;
    }

    public static void main(String[] a) throws Exception {
        Class.forName("cubrid.jdbc.driver.CUBRIDDriver");
        url = "jdbc:cubrid:localhost:" + a[0] + ":" + a[1] + ":";
        if (a.length > 2 && a[2].equals("loop")) {
            loop(Integer.parseInt(a[3]), Integer.parseInt(a[4]));
            return;
        }
        if (a.length > 2 && a[2].equals("dump")) {
            dump();
            return;
        }
        if (a.length > 2 && a[2].equals("send")) {
            try (Connection c = DriverManager.getConnection(url + "dba::")) {
                UConnection u = jci(c);
                UStatement us = u.getSchemaInfo(Integer.parseInt(a[3]), a[4], "%", (byte) 3,
                        UShardInfo.SHARD_ID_INVALID);
                System.out.println("sub-type " + a[3] + " -> server code " + u.getRecentError().getJdbcErrorCode());
                if (us != null) us.close();
            }
            return;
        }

        Connection dba = DriverManager.getConnection(url + "dba::");
        dbaConn = dba;
        UConnection u = jci(dba);
        System.out.println("server " + dba.getMetaData().getDatabaseProductVersion());
        tearDown(dba);
        setUp(dba);
        try {
            checks(dba, u);
        } finally {
            dba.setAutoCommit(true);
            tearDown(dba);
            dba.close();
        }
        System.out.println(failures == 0 ? "ALL PASS" : failures + " FAILED");
        System.exit(failures);
    }

    static void checks(Connection dba, UConnection u) throws Exception {
        check("lists every schema that schemata lists", () -> {
            List<String> got = viaSubType(u, null, PATTERN);
            assertEq(viaSql(dba, oracleSql(dba, null)), got);
            assertTrue(got.containsAll(Arrays.asList("DBA", "PUBLIC", "ZZ_PROBE_A", "ZZXPROBE_B", "ZZ_PROBE_C")),
                    "fixture schemas listed: " + got);
        });

        check("describes one string column named NAME", () -> {
            UStatement us = open(u, SCH_SCHEMA, null, PATTERN);
            UColumnInfo[] ci = us.getColumnInfo();
            us.close();
            assertEq(1, ci.length);
            assertEq("NAME", ci[0].getColumnName());
            assertEq(UUType.U_TYPE_STRING, ci[0].getColumnType());
        });

        check("a LIKE pattern keeps the matching schemas", () -> {
            List<String> got = viaSubType(u, "ZZ%", PATTERN);
            assertEq(viaSql(dba, oracleSql(dba, "ZZ%")), got);
            assertEq(3, got.size());
        });

        check("an escaped underscore matches only an underscore", () ->
                assertEq(Arrays.asList("ZZ_PROBE_A", "ZZ_PROBE_C"), viaSubType(u, "ZZ\\_PROBE%", PATTERN)));

        check("the pattern ignores case, like owner names elsewhere in CAS", () ->
                assertEq(Arrays.asList("ZZ_PROBE_A"), viaSubType(u, "zz\\_probe\\_a", PATTERN)));

        check("without the pattern flag the name must match exactly", () -> {
            assertEq(Arrays.asList("ZZ_PROBE_A"), viaSubType(u, "zz_probe_a", EXACT));
            assertEq(Collections.emptyList(), viaSubType(u, "ZZ%", EXACT));
            assertEq(Collections.emptyList(), viaSubType(u, null, EXACT));
        });

        check("a user outside DBA gets what schemata shows that user", () -> {
            try (Connection ca = DriverManager.getConnection(url + "zz_probe_a::")) {
                List<String> got = viaSubType(jci(ca), null, PATTERN);
                assertEq(viaSql(ca, oracleSql(ca, null)), got);
                assertTrue(got.contains("ZZ_PROBE_C"), "schema of the granted table listed: " + got);
            }
        });

        check("the open transaction is left alone", () -> {
            dba.setAutoCommit(false);
            exec(dba, "insert into zz_probe_txn values (1)");
            viaSubType(u, null, PATTERN);
            assertEq(1, count(dba, "select count(*) from zz_probe_txn"));
            dba.rollback();
            assertEq(0, count(dba, "select count(*) from zz_probe_txn"));
            dba.setAutoCommit(true);
        });

        check("a commit ends the result the same way it ends sub-type 1", () -> {
            dba.setAutoCommit(false);
            String classAfterCommit = fetchAfterCommit(u, SCH_CLASS, "%");
            String schemaAfterCommit = fetchAfterCommit(u, SCH_SCHEMA, null);
            dba.setAutoCommit(true);
            System.out.println("      sub-type 1: " + classAfterCommit + ", sub-type 21: " + schemaAfterCommit);
            assertEq(classAfterCommit, schemaAfterCommit);
        });

        int rejected = Integer.getInteger("reject", 22);
        check("sub-type " + rejected + " is still rejected and the connection stays", () -> {
            dba.setAutoCommit(false);
            exec(dba, "insert into zz_probe_txn values (1)");
            UStatement us = u.getSchemaInfo(rejected, null, null, PATTERN, UShardInfo.SHARD_ID_INVALID);
            assertTrue(us == null, "no statement for " + rejected);
            assertEq(UErrorCode.CAS_ER_SCHEMA_TYPE, u.getRecentError().getJdbcErrorCode());
            assertEq(1, count(dba, "select count(*) from zz_probe_txn"));
            dba.rollback();
            dba.setAutoCommit(true);
        });
    }

    /* Opens a schema-info result, commits, then asks for the first row. */
    static String fetchAfterCommit(UConnection u, int type, String arg1) {
        UStatement us = open(u, type, arg1, PATTERN);
        u.endTransaction(true);
        us.moveCursor(0, UStatement.CURSOR_SET);
        int move = us.getRecentError().getJdbcErrorCode();
        us.fetch();
        int fetch = us.getRecentError().getJdbcErrorCode();
        us.close();
        return "move=" + move + " fetch=" + fetch;
    }

    /*
     * n x (schema info, fetch every row, close, commit) on one connection, so one CAS serves it all.
     * The resident size of that CAS is read after a warm-up and at the end.
     */
    static void loop(int type, int n) throws Exception {
        try (Connection c = DriverManager.getConnection(url + "dba::")) {
            UConnection u = jci(c);
            int pid = u.getCasProcessId();
            String arg1 = type == SCH_CLASS ? "%" : null;
            int rows = calls(u, type, arg1, 300);
            long before = casRssKb(pid);
            calls(u, type, arg1, n);
            if (u.getCasProcessId() != pid) {
                throw new IllegalStateException("the CAS changed during the run: " + pid + " -> " + u.getCasProcessId());
            }
            long after = casRssKb(pid);
            System.out.println("sub-type " + type + ": cas pid " + pid + ", " + rows + " rows a call, RSS " + before
                    + " KB -> " + after + " KB over " + n + " calls (grew " + (after - before) + " KB)");
        }
    }

    static int calls(UConnection u, int type, String arg1, int n) {
        int rows = 0;
        for (int i = 0; i < n; i++) {
            UStatement us = open(u, type, arg1, PATTERN);
            rows = drain(us).size();
            us.close();
            /* the driver sends a deferred close of a schema-info handle only with the next PREPARE */
            UStatement flush = u.prepare("select 1", (byte) 0);
            flush.close();
            /* the driver commits after a metadata call in auto-commit mode; the server allows 100 queries a transaction */
            u.endTransaction(true);
        }
        return rows;
    }

    /* The probe runs next to the broker, so the CAS is in this /proc. */
    static long casRssKb(int pid) throws Exception {
        for (String line : java.nio.file.Files.readAllLines(java.nio.file.Paths.get("/proc/" + pid + "/status"))) {
            if (line.startsWith("VmRSS:")) {
                return Long.parseLong(line.replaceAll("[^0-9]", ""));
            }
        }
        throw new IllegalStateException("no VmRSS for CAS " + pid);
    }

    /* Every earlier sub-type, scoped to one fixture so two servers can be compared line by line. */
    static void dump() throws Exception {
        try (Connection dba = DriverManager.getConnection(url + "dba::")) {
            UConnection u = jci(dba);
            dropDumpFixture(dba);
            exec(dba, "create table zz_probe_pk (id int primary key, v varchar(10))");
            exec(dba, "create table zz_probe_fk (id int primary key, pk_id int,"
                    + " foreign key (pk_id) references zz_probe_pk (id))");
            exec(dba, "create view zz_probe_v as select id, v from zz_probe_pk");
            exec(dba, "create synonym zz_probe_syn for zz_probe_pk");
            Object[][] calls = {
                {1, "zz_probe%", null, 3}, {2, "zz_probe%", null, 3}, {3, "zz_probe_v", null, 0},
                {4, "zz_probe_pk", "%", 3}, {5, "zz_probe_pk", "%", 3}, {6, "zz_probe_pk", null, 0},
                {7, "zz_probe_pk", null, 0}, {8, "zz_probe_pk", null, 0}, {9, "zz_probe_pk", null, 0},
                {10, "zz_probe_pk", null, 0}, {11, "zz_probe_fk", null, 2}, {12, "zz_probe%", null, 1},
                {13, "zz_probe_pk", null, 0}, {14, "zz_probe_pk", "%", 2}, {15, "zz_probe%", null, 1},
                {16, "zz_probe_pk", null, 0}, {17, "zz_probe_fk", null, 0}, {18, "zz_probe_pk", null, 0},
                {19, "zz_probe_pk", "zz_probe_fk", 0}, {20, "zz_probe_syn", "%", 3},
            };
            for (Object[] c : calls) {
                int type = (Integer) c[0];
                UStatement us = u.getSchemaInfo(type, (String) c[1], (String) c[2], (byte) (int) (Integer) c[3],
                        UShardInfo.SHARD_ID_INVALID);
                UError e = u.getRecentError();
                if (e.getErrorCode() != UErrorCode.ER_NO_ERROR) {
                    System.out.println("type " + type + ": error " + e.getJdbcErrorCode());
                    continue;
                }
                UColumnInfo[] ci = us.getColumnInfo();
                List<String> cols = new ArrayList<>();
                for (UColumnInfo col : ci) cols.add(col.getColumnName());
                List<String> rows = new ArrayList<>();
                for (int i = 0; ; i++) {
                    us.moveCursor(i, UStatement.CURSOR_SET);
                    if (us.getRecentError().getErrorCode() != UErrorCode.ER_NO_ERROR) break;
                    us.fetch();
                    List<String> row = new ArrayList<>();
                    for (int j = 0; j < ci.length; j++) row.add(String.valueOf(us.getObject(j)));
                    rows.add(row.toString());
                }
                us.close();
                System.out.println("type " + type + " " + cols + " " + rows);
            }
            dropDumpFixture(dba);
        }
    }

    static void dropDumpFixture(Connection dba) {
        for (String sql : new String[] {"drop synonym if exists zz_probe_syn", "drop view if exists zz_probe_v",
                "drop table if exists zz_probe_fk", "drop table if exists zz_probe_pk"}) {
            try {
                exec(dba, sql);
            } catch (SQLException ignored) {
                /* not there yet */
            }
        }
    }

    static void setUp(Connection dba) throws SQLException {
        dba.setAutoCommit(true);
        exec(dba, "create user zz_probe_a");
        exec(dba, "create user zzxprobe_b");
        exec(dba, "create user zz_probe_c");
        exec(dba, "create table zz_probe_txn (a int)");
        try (Connection c = DriverManager.getConnection(url + "zz_probe_c::")) {
            c.setAutoCommit(true);
            exec(c, "create table zz_probe_t (a int)");
            exec(c, "grant select on zz_probe_t to zz_probe_a");
        }
    }

    static void tearDown(Connection dba) throws SQLException {
        dba.setAutoCommit(true);
        for (String sql : new String[] {"drop table if exists zz_probe_c.zz_probe_t", "drop table if exists zz_probe_txn",
                "drop user zz_probe_a", "drop user zzxprobe_b", "drop user zz_probe_c"}) {
            try {
                exec(dba, sql);
            } catch (SQLException ignored) {
                /* not there yet */
            }
        }
    }

    static UStatement open(UConnection u, int type, String arg1, byte flag) {
        UStatement us = u.getSchemaInfo(type, arg1, null, flag, UShardInfo.SHARD_ID_INVALID);
        UError e = u.getRecentError();
        if (e.getErrorCode() != UErrorCode.ER_NO_ERROR) {
            throw new IllegalStateException("sub-type " + type + " failed: jci=" + e.getErrorCode()
                    + " server=" + e.getJdbcErrorCode() + " " + e.getErrorMsg(false));
        }
        return us;
    }

    static List<String> viaSubType(UConnection u, String arg1, byte flag) {
        UStatement us = open(u, SCH_SCHEMA, arg1, flag);
        List<String> names = drain(us);
        us.close();
        return names;
    }

    static List<String> drain(UStatement us) {
        List<String> names = new ArrayList<>();
        for (int i = 0; ; i++) {
            us.moveCursor(i, UStatement.CURSOR_SET);
            if (us.getRecentError().getErrorCode() != UErrorCode.ER_NO_ERROR) break;
            us.fetch();
            names.add(us.getString(0));
        }
        return names;
    }

    /* The server's own list: schemata where it exists (11.5), the user catalog before it. */
    static String oracleSql(Connection c, String like) {
        boolean schemata;
        try (Statement s = c.createStatement()) {
            s.executeQuery("select 1 from information_schema.schemata where 1 = 0").close();
            schemata = true;
        } catch (SQLException e) {
            schemata = false;
        }
        String col = schemata ? "schema_name" : "name";
        String from = schemata ? "information_schema.schemata" : "db_user";
        return "select " + col + " from " + from + (like == null ? "" : " where " + col + " like '" + like + "'")
                + " order by " + col;
    }

    static List<String> viaSql(Connection c, String sql) throws SQLException {
        List<String> r = new ArrayList<>();
        try (Statement s = c.createStatement(); ResultSet rs = s.executeQuery(sql)) {
            while (rs.next()) r.add(rs.getString(1));
        }
        return r;
    }

    static int count(Connection c, String sql) throws SQLException {
        try (Statement s = c.createStatement(); ResultSet rs = s.executeQuery(sql)) {
            rs.next();
            return rs.getInt(1);
        }
    }

    static void exec(Connection c, String sql) throws SQLException {
        try (Statement s = c.createStatement()) {
            s.executeUpdate(sql);
        }
    }

    static UConnection jci(Connection c) throws Exception {
        Field f = Class.forName("cubrid.jdbc.driver.CUBRIDConnection").getDeclaredField("u_con");
        f.setAccessible(true);
        return (UConnection) f.get(c);
    }

    static void check(String name, Check body) {
        try {
            body.run();
            System.out.println("PASS  " + name);
        } catch (Throwable t) {
            failures++;
            System.out.println("FAIL  " + name + "\n      " + t.getMessage());
        } finally {
            reset();
        }
    }

    /* A check that fails half way must not leave its transaction to the next one. */
    static void reset() {
        try {
            if (!dbaConn.getAutoCommit()) dbaConn.rollback();
            dbaConn.setAutoCommit(true);
            exec(dbaConn, "delete from zz_probe_txn");
        } catch (SQLException e) {
            throw new IllegalStateException("reset failed", e);
        }
    }

    static void assertEq(Object want, Object got) {
        if (!Objects.equals(want, got)) throw new AssertionError("want " + want + " but got " + got);
    }

    static void assertTrue(boolean ok, String what) {
        if (!ok) throw new AssertionError("expected: " + what);
    }
}

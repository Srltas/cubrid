import org.junit.runner.JUnitCore;
import org.junit.runner.Request;
import org.junit.runner.Result;
import org.junit.runner.notification.Failure;

/* The schema TCs: TestSchemaMetaDataMatchesServer, test4, test31 and TestUSchType, against ./jdbc.properties. */
public class RunSchemaTcs {
    public static void main(String[] a) throws Exception {
        Request[] requests = {
            Request.aClass(Class.forName("cubrid.jdbc.driver.TestSchemaMetaDataMatchesServer")),
            Request.method(Class.forName("cubrid.jdbc.driver.TestCUBRIDDatabaseMetaData"), "test4"),
            Request.method(Class.forName("cubrid.jdbc.driver.TestCUBRIDDatabaseMetaData2"), "test31"),
            Request.aClass(Class.forName("cubrid.jdbc.jci.TestUSchType")),
        };
        int runs = 0, failures = 0;
        for (Request r : requests) {
            Result result = new JUnitCore().run(r);
            runs += result.getRunCount();
            for (Failure f : result.getFailures()) {
                failures++;
                String m = String.valueOf(f.getMessage());
                System.out.println("FAIL " + f.getDescription().getMethodName() + ": " + (m.length() > 200 ? m.substring(0, 200) : m));
            }
        }
        System.out.println("run=" + runs + " failed=" + failures);
        System.exit(failures);
    }
}

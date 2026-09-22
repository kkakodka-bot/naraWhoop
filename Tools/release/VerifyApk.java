import com.android.apksig.ApkVerifier;

import java.io.File;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HexFormat;
import java.util.List;

/**
 * Minimal offline APK signature inspector used by release-artifact-manifest.mjs.
 *
 * Run in Java source-file mode with the exact Gradle-resolved apksig jar:
 *   java -cp /path/to/apksig.jar Tools/release/VerifyApk.java app.apk
 */
public final class VerifyApk {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("expected one APK path");
        }
        ApkVerifier.Result result = new ApkVerifier.Builder(new File(args[0])).build().verify();
        if (!result.isVerified()) {
            System.err.println("APK_SIGNATURE_NOT_VERIFIED");
            System.exit(2);
        }
        List<String> certificates = new ArrayList<>();
        MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
        for (X509Certificate certificate : result.getSignerCertificates()) {
            certificates.add(HexFormat.of().formatHex(sha256.digest(certificate.getEncoded())));
        }
        Collections.sort(certificates);
        if (certificates.isEmpty()) {
            throw new IllegalStateException("verified APK has no signer certificate");
        }
        StringBuilder json = new StringBuilder();
        json.append("{\"certificateSha256\":[");
        for (int index = 0; index < certificates.size(); index++) {
            if (index > 0) json.append(',');
            json.append('\"').append(certificates.get(index)).append('\"');
        }
        json.append("],\"verified\":true")
            .append(",\"v1\":").append(result.isVerifiedUsingV1Scheme())
            .append(",\"v2\":").append(result.isVerifiedUsingV2Scheme())
            .append(",\"v3\":").append(result.isVerifiedUsingV3Scheme())
            .append(",\"v31\":").append(result.isVerifiedUsingV31Scheme())
            .append(",\"v4\":").append(result.isVerifiedUsingV4Scheme())
            .append('}');
        System.out.println(json);
    }
}

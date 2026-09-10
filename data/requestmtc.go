// requestmtc.go requests a MTC certificate for a domain from a (local, e.g.
// Pebble) ACME server via lego, then configures Apache to serve a small
// hello-world site for that domain over HTTPS with an HTTP->HTTPS redirect.
// Optionally, if -relative is true, it converts the issued standalone certificate
// into its landmark-relative form (draft §6.3.3) via cactus-cli and uses that cert
// in the Apache config for this domain instead of the standalone cert.
//
// Usage:
//
//	go run requestmtc.go -domain example.test
//	go run requestmtc.go -domain example.test -relative
//	go run requestmtc.go -domain example.test -relative -tai
//	go run requestmtc.go -domain example.test -email me@example.com -relative -tai
//	go run requestmtc.go -domain example.test -log https://ca1.test.mtcs.dev/1 -relative -tai
//
package main

import (
	"bytes"
	"crypto/x509"
	"encoding/asn1"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// landmarkRetryInterval is how often to re-attempt the landmark-relative
// conversion while waiting for a landmark to cover the new entry. Landmarks
// are allocated on a fixed interval (cactus-config.json landmarks
// .time_between_landmarks_ms, 3600000ms = 1h by default).
const landmarkRetryInterval = 15 * time.Second

func main() {
	domain := flag.String("domain", "", "comma-separated domain(s) to request certificate(s) for (required)")
	email := flag.String("email", "you@example.com", "ACME account email")
	server := flag.String("server", "http://localhost:14000/directory", "ACME server directory URL")
	certPath := flag.String("path", "./certs", "lego --path directory (certs land in <path>/certificates)")
	logURL := flag.String("log", "http://localhost:14080/1", "cactus log URL (monitoring endpoint + log number) used to build the landmark-relative cert")
	cli := flag.String("cactus-cli", "cactus-cli", "path to the cactus-cli binary")
	landmarkWait := flag.Duration("landmark-wait", 70*time.Minute, "how long to wait for a landmark covering the freshly issued entry")
	relative := flag.Bool("relative", false, "whether to obtain and use a landmark-relative cert in Apache config")
	tai := flag.Bool("tai", false, "whether to attach a TAI CERTIFICATE PROPERTIES block to the landmark-relative cert")
	flag.Parse()

	var domains []string
	for _, d := range strings.Split(*domain, ",") {
		d = strings.TrimSpace(d)
		if d != "" {
			domains = append(domains, d)
		}
	}
	if len(domains) == 0 {
		fmt.Fprintln(os.Stderr, "error: -domain is required")
		flag.Usage()
		os.Exit(1)
	}

	if err := run(domains, *email, *server, *certPath, *logURL, *cli, *landmarkWait, *relative, *tai); err != nil {
		log.Fatalf("error: %v", err)
	}
}

type stagedCert struct {
	domain   string
	certFile string
	keyFile  string
	pemFile  string
	lrFile   string
}

func run(domains []string, email, server, certPath, logURL, cli string, landmarkWait time.Duration, relative, tai bool) error {
	if relative && logURL == "" {
		return fmt.Errorf("-relative requires a non-empty -log URL")
	}

	absCertPath, err := filepath.Abs(certPath)
	if err != nil {
		return fmt.Errorf("resolving cert path: %w", err)
	}
	liveCertDir := filepath.Join(absCertPath, "certificates")
	liveAccountsDir := filepath.Join(absCertPath, "accounts")

	// Stage lego output in a temporary directory so that live certificates and
	// keys in certPath/certificates are not overwritten until the final cert
	// (including landmark-relative conversion when -relative is set) is ready.
	stagingDir, err := os.MkdirTemp("", "requestmtc-staging-*")
	if err != nil {
		return fmt.Errorf("creating staging dir: %w", err)
	}
	defer os.RemoveAll(stagingDir)

	if _, err := os.Stat(liveAccountsDir); err == nil {
		if err := copyDir(liveAccountsDir, filepath.Join(stagingDir, "accounts")); err != nil {
			return fmt.Errorf("copying ACME accounts to staging: %w", err)
		}
	}

	stagingCertDir := filepath.Join(stagingDir, "certificates")
	var staged []stagedCert

	// 1. Request the standalone certificate with lego for all domains upfront
	// so every entry is logged before we start waiting for the next landmark.
	for _, domain := range domains {
		logStep("Requesting certificate for %s from %s", domain, server)
		lego := exec.Command("lego",
			"--server", server,
			"--email", email,
			"--domains", domain,
			"--accept-tos",
			"--http",
			"--pem",
			"--path", stagingDir,
			"run",
		)
		lego.Stdout = os.Stdout
		lego.Stderr = os.Stderr
		log.Printf("running: %s", strings.Join(lego.Args, " "))
		if err := lego.Run(); err != nil {
			return fmt.Errorf("lego run for %s failed (see output above): %w", domain, err)
		}

		sc := stagedCert{
			domain:   domain,
			certFile: filepath.Join(stagingCertDir, domain+".crt"),
			keyFile:  filepath.Join(stagingCertDir, domain+".key"),
			pemFile:  filepath.Join(stagingCertDir, domain+".pem"),
			lrFile:   filepath.Join(stagingCertDir, domain+"-landmark-relative.pem"),
		}
		for _, f := range []string{sc.certFile, sc.keyFile, sc.pemFile} {
			if _, err := os.Stat(f); err != nil {
				return fmt.Errorf("expected cert artifact missing in staging: %s", f)
			}
		}
		staged = append(staged, sc)
	}
	logStep("All %d certificate(s) staged under %s", len(staged), stagingCertDir)

	// Persist any updated ACME account state back to certPath/accounts.
	stagingAccountsDir := filepath.Join(stagingDir, "accounts")
	if _, err := os.Stat(stagingAccountsDir); err == nil {
		if err := copyDir(stagingAccountsDir, liveAccountsDir); err != nil {
			log.Printf("==> warning: failed to sync ACME accounts back to %s: %v", liveAccountsDir, err)
		}
	}

	// 2. If -relative is set, convert all staged standalone certs into their
	// landmark-relative form before touching the live cert directory or Apache.
	// Since all entries were logged in Step 1, once the first domain is covered
	// by the newly allocated landmark, all subsequent domains will convert immediately.
	if relative {
		for i := range staged {
			sc := &staged[i]
			inputPem := sc.pemFile
			if tai {
				withPropsFile, err := prepareTAIInput(sc.pemFile, stagingCertDir, sc.domain)
				if err != nil {
					return fmt.Errorf("attaching TAI properties for %s: %w", sc.domain, err)
				}
				inputPem = withPropsFile
				logStep("Standalone cert with TAI properties written to %s", withPropsFile)
			}

			if err := landmarkRelative(cli, inputPem, logURL, sc.lrFile, landmarkWait); err != nil {
				return fmt.Errorf("obtaining landmark-relative certificate for %s: %w", sc.domain, err)
			}
		}
	}

	// 3. Install the ready certificates and keys into liveCertDir, configure
	// document roots, and write Apache VirtualHost configs.
	if err := os.MkdirAll(liveCertDir, 0755); err != nil {
		return fmt.Errorf("creating live cert dir %s: %w", liveCertDir, err)
	}

	for _, sc := range staged {
		domain := sc.domain
		keyBytes, err := os.ReadFile(sc.keyFile)
		if err != nil {
			return fmt.Errorf("reading staged key for %s: %w", domain, err)
		}
		keyFile := filepath.Join(liveCertDir, domain+".key")
		if err := writeFileAtomic(keyFile, keyBytes, 0600); err != nil {
			return fmt.Errorf("installing key %s: %w", keyFile, err)
		}

		var certToUse string
		if relative {
			lrBytes, err := os.ReadFile(sc.lrFile)
			if err != nil {
				return fmt.Errorf("reading staged landmark-relative cert for %s: %w", domain, err)
			}
			lrFile := filepath.Join(liveCertDir, domain+"-landmark-relative.pem")
			if err := writeFileAtomic(lrFile, lrBytes, 0644); err != nil {
				return fmt.Errorf("installing landmark-relative cert %s: %w", lrFile, err)
			}
			// Also write the landmark-relative cert to .crt and .pem so no standalone
			// certificate ever exists in liveCertDir for a relative domain.
			certFile := filepath.Join(liveCertDir, domain+".crt")
			if err := writeFileAtomic(certFile, lrBytes, 0644); err != nil {
				return fmt.Errorf("installing cert %s: %w", certFile, err)
			}
			pemFile := filepath.Join(liveCertDir, domain+".pem")
			if err := writeFileAtomic(pemFile, append(append([]byte(nil), lrBytes...), keyBytes...), 0600); err != nil {
				return fmt.Errorf("installing pem %s: %w", pemFile, err)
			}
			certToUse = lrFile
			logStep("Installed landmark-relative certificate to %s", lrFile)
		} else {
			certBytes, err := os.ReadFile(sc.certFile)
			if err != nil {
				return fmt.Errorf("reading staged cert for %s: %w", domain, err)
			}
			pemBytes, err := os.ReadFile(sc.pemFile)
			if err != nil {
				return fmt.Errorf("reading staged pem for %s: %w", domain, err)
			}
			certFile := filepath.Join(liveCertDir, domain+".crt")
			if err := writeFileAtomic(certFile, certBytes, 0644); err != nil {
				return fmt.Errorf("installing cert %s: %w", certFile, err)
			}
			pemFile := filepath.Join(liveCertDir, domain+".pem")
			if err := writeFileAtomic(pemFile, pemBytes, 0600); err != nil {
				return fmt.Errorf("installing pem %s: %w", pemFile, err)
			}
			certToUse = certFile
			logStep("Installed standalone certificate to %s", certFile)
		}

		// Create a document root with a basic hello-world page.
		var hostDocRoot string
		if _, err := exec.LookPath("a2ensite"); err == nil {
			hostDocRoot = filepath.Join("/var/www", domain)
		} else {
			hostDocRoot, _ = filepath.Abs(filepath.Join("www", domain))
		}
		logStep("Creating document root %s", hostDocRoot)
		if err := os.MkdirAll(hostDocRoot, 0755); err != nil {
			_ = sudoRun("mkdir", "-p", hostDocRoot)
		}
		indexPath := filepath.Join(hostDocRoot, "index.html")
		if err := os.WriteFile(indexPath, []byte(indexHTML(domain)), 0644); err != nil {
			_ = sudoWriteFile(indexPath, indexHTML(domain))
		}
		logStep("Hello world page written to %s", indexPath)

		// Write web server VirtualHost config (<domain>.conf)
		confName := domain + ".conf"

		if _, err := exec.LookPath("a2ensite"); err == nil {
			// Standard non-Docker VM with host Apache installed
			confPath := filepath.Join("/etc/apache2/sites-available", confName)
			logStep("Writing Apache config %s (using certificate %s)", confPath, certToUse)
			if err := sudoWriteFile(confPath, vhostConf(domain, hostDocRoot, certToUse, keyFile)); err != nil {
				return fmt.Errorf("writing apache config for %s: %w", domain, err)
			}
			logStep("Enabling mod_ssl and site %s", confName)
			_ = sudoRun("a2enmod", "ssl")
			_ = sudoRun("a2ensite", confName)
		} else {
			// Docker-based setup (Nginx)
			relCert, err := filepath.Rel(liveCertDir, certToUse)
			if err != nil {
				relCert = filepath.Base(certToUse)
			}
			containerCertPath := "/etc/certs/certificates/" + relCert
			containerKeyPath := "/etc/certs/certificates/" + domain + ".key"
			containerDocRoot := "/var/www/" + domain

			hostSitesDir, err := filepath.Abs("sites-enabled")
			if err != nil {
				return fmt.Errorf("resolving sites-enabled dir: %w", err)
			}
			if err := os.MkdirAll(hostSitesDir, 0755); err != nil {
				return fmt.Errorf("creating sites-enabled dir: %w", err)
			}
			confPath := filepath.Join(hostSitesDir, confName)
			logStep("Writing Nginx config %s (container cert %s)", confPath, containerCertPath)
			if err := os.WriteFile(confPath, []byte(nginxVhostConf(domain, containerDocRoot, containerCertPath, containerKeyPath)), 0644); err != nil {
				return fmt.Errorf("writing nginx config for %s: %w", domain, err)
			}
		}
	}

	// 4. Reload web server once after all configs are written.
	if _, err := exec.LookPath("a2ensite"); err == nil {
		logStep("Validating Apache configuration")
		if err := sudoRun("apache2ctl", "configtest"); err == nil {
			logStep("Reloading Apache")
			_ = sudoRun("systemctl", "reload-or-restart", "apache2")
		}
	} else {
		logStep("Reloading Nginx in Docker container (cactus-nginx-1)")
		reloadCmd := exec.Command("docker", "exec", "cactus-nginx-1", "nginx", "-s", "reload")
		reloadCmd.Stdout = os.Stdout
		reloadCmd.Stderr = os.Stderr
		if err := reloadCmd.Run(); err != nil {
			log.Printf("==> warning: failed to reload Nginx container: %v", err)
		} else {
			logStep("Nginx container reloaded successfully.")
		}
	}

	logStep("Done. Certificate(s) for %s ready.", strings.Join(domains, ", "))
	return nil
}

// landmarkRelative converts the standalone certificate at certFile into its
// landmark-relative form (§6.3.3) with `cactus-cli cert landmark-relative`,
// writing the PEM the command prints on stdout to outFile.
func landmarkRelative(cli, certFile, logURL, outFile string, wait time.Duration) error {
	logStep("Building landmark-relative certificate from %s", filepath.Base(certFile))
	deadline := time.Now().Add(wait)
	for {
		cmd := exec.Command(cli, "cert", "landmark-relative", certFile, logURL)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		log.Printf("running: %s", strings.Join(cmd.Args, " "))
		err := cmd.Run()
		if err == nil {
			if err := os.WriteFile(outFile, stdout.Bytes(), 0644); err != nil {
				return fmt.Errorf("writing %s: %w", outFile, err)
			}
			if s := strings.TrimSpace(stderr.String()); s != "" {
				log.Printf("    %s", s)
			}
			logStep("Landmark-relative certificate written to %s", outFile)
			return nil
		}
		msg := strings.TrimSpace(stderr.String())
		if !strings.Contains(msg, "no active landmark covers") {
			if msg == "" {
				return err
			}
			return fmt.Errorf("%s", msg)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("no landmark covered the entry within %s; once one is allocated, build it with:\n\t%s",
				wait, strings.Join(cmd.Args, " "))
		}
		log.Printf("    entry not covered by a landmark yet; retrying in %s", landmarkRetryInterval)
		time.Sleep(landmarkRetryInterval)
	}
}

// logStep prints a highlighted progress line so each stage is easy to follow.
func logStep(format string, args ...any) {
	log.Printf("==> "+format, args...)
}

func indexHTML(domain string) string {
	return fmt.Sprintf(`<!DOCTYPE html>
<html>
  <head><title>%s</title></head>
  <body>
    <h1>Hello, world!</h1>
    <p>Served over HTTPS by %s.</p>
  </body>
</html>
`, domain, domain)
}

func vhostConf(domain, docRoot, certFile, keyFile string) string {
	return fmt.Sprintf(`<VirtualHost *:80>
    ServerName %[1]s
    ProxyPreserveHost On
    ProxyPass /.well-known/acme-challenge/ !
    Redirect permanent / https://%[1]s/
</VirtualHost>

<VirtualHost *:443>
    ServerName %[1]s
    DocumentRoot %[2]s

    SSLEngine on
    SSLCertificateFile %[3]s
    SSLCertificateKeyFile %[4]s

    # Pebble test certs use a weak signature digest that OpenSSL's default
    # security level (2) rejects; lower it so Apache will load the cert.
    # See https://github.com/openssl/openssl/issues/31195
    SSLCipherSuite DEFAULT:@SECLEVEL=0

    <Directory %[2]s>
        Require all granted
    </Directory>
</VirtualHost>
`, domain, docRoot, certFile, keyFile)
}

func nginxVhostConf(domain, docRoot, certFile, keyFile string) string {
	return fmt.Sprintf(`server {
    listen 80;
    server_name %[1]s;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 4443 ssl;
    server_name %[1]s;

    root %[2]s;
    index index.html;

    ssl_certificate %[3]s;
    ssl_certificate_key %[4]s;

    # Pebble test certs use a weak signature digest that OpenSSL's default
    # security level (2) rejects; lower it so OpenSSL will load the cert.
    ssl_ciphers DEFAULT:@SECLEVEL=0;
}
`, domain, docRoot, certFile, keyFile)
}

// sudoRun runs a command as root, streaming its output to the terminal.
func sudoRun(name string, args ...string) error {
	cmd := exec.Command("sudo", append([]string{name}, args...)...)
	log.Printf("running: %s", strings.Join(cmd.Args, " "))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// sudoWriteFile writes content to a root-owned path via `sudo tee`.
func sudoWriteFile(path, content string) error {
	log.Printf("writing: %s (%d bytes)", path, len(content))
	cmd := exec.Command("sudo", "tee", path)
	cmd.Stdin = strings.NewReader(content)
	cmd.Stdout = io.Discard // tee echoes stdin; we don't need it on the terminal
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

var oidTrustAnchorID = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 44363, 47, 1}

func prepareTAIInput(pemFile, certDir, domain string) (string, error) {
	raw, err := os.ReadFile(pemFile)
	if err != nil {
		return "", err
	}
	caID, err := extractCAID(raw)
	if err != nil {
		return "", err
	}
	propsPEM, err := buildCAPropertiesBlock(caID)
	if err != nil {
		return "", err
	}

	content := append(propsPEM, raw...)
	outFile := filepath.Join(certDir, domain+"-standalone-with-props.pem")
	if err := os.WriteFile(outFile, content, 0644); err != nil {
		return "", err
	}
	return outFile, nil
}

func extractCAID(certPEM []byte) (string, error) {
	block, _ := pem.Decode(certPEM)
	if block == nil {
		return "", fmt.Errorf("no pem block found")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", err
	}
	for _, name := range cert.Issuer.Names {
		if name.Type.Equal(oidTrustAnchorID) {
			return fmt.Sprintf("%v", name.Value), nil
		}
	}
	return "", fmt.Errorf("trustAnchorID attribute not found in issuer DN")
}

func buildCAPropertiesBlock(caID string) ([]byte, error) {
	var body []byte
	for _, part := range strings.Split(caID, ".") {
		var v uint64
		if _, err := fmt.Sscanf(part, "%d", &v); err != nil {
			return nil, fmt.Errorf("invalid CA ID arc %q: %w", part, err)
		}
		body = appendBase128(body, v)
	}
	prop := append([]byte{0x00, 0x00, byte(len(body) >> 8), byte(len(body))}, body...)
	list := append([]byte{byte(len(prop) >> 8), byte(len(prop))}, prop...)

	block := &pem.Block{
		Type:  "CERTIFICATE PROPERTIES",
		Bytes: list,
	}
	return pem.EncodeToMemory(block), nil
}

func appendBase128(dst []byte, v uint64) []byte {
	var buf [10]byte
	n := len(buf)
	n--
	buf[n] = byte(v & 0x7f)
	for v >>= 7; v > 0; v >>= 7 {
		n--
		buf[n] = byte(v&0x7f) | 0x80
	}
	return append(dst, buf[n:]...)
}

func writeFileAtomic(dst string, data []byte, perm os.FileMode) error {
	tmp := dst + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

func copyDir(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, info.Mode())
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode())
	})
}


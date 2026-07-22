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
// .time_between_landmarks_ms, 60s by default), so polling faster than this
// just adds noise.
const landmarkRetryInterval = 5 * time.Second

func main() {
	domain := flag.String("domain", "", "domain to request a certificate for (required)")
	email := flag.String("email", "you@example.com", "ACME account email")
	server := flag.String("server", "http://localhost:14000/directory", "ACME server directory URL")
	certPath := flag.String("path", "./certs", "lego --path directory (certs land in <path>/certificates)")
	logURL := flag.String("log", "http://localhost:14080/1", "cactus log URL (monitoring endpoint + log number) used to build the landmark-relative cert")
	cli := flag.String("cactus-cli", "cactus-cli", "path to the cactus-cli binary")
	landmarkWait := flag.Duration("landmark-wait", 90*time.Second, "how long to wait for a landmark covering the freshly issued entry")
	relative := flag.Bool("relative", false, "whether to obtain and use a landmark-relative cert in Apache config")
	tai := flag.Bool("tai", false, "whether to attach a TAI CERTIFICATE PROPERTIES block to the landmark-relative cert")
	flag.Parse()

	if *domain == "" {
		fmt.Fprintln(os.Stderr, "error: -domain is required")
		flag.Usage()
		os.Exit(1)
	}

	if err := run(*domain, *email, *server, *certPath, *logURL, *cli, *landmarkWait, *relative, *tai); err != nil {
		log.Fatalf("error: %v", err)
	}
}

func run(domain, email, server, certPath, logURL, cli string, landmarkWait time.Duration, relative, tai bool) error {
	// 1. Request the certificate with lego.
	logStep("Requesting certificate for %s from %s", domain, server)
	lego := exec.Command("lego",
		"--server", server,
		"--email", email,
		"--domains", domain,
		"--accept-tos",
		"--http",
		"--pem",
		"--path", certPath,
		"run",
	)
	lego.Stdout = os.Stdout
	lego.Stderr = os.Stderr
	log.Printf("running: %s", strings.Join(lego.Args, " "))
	if err := lego.Run(); err != nil {
		return fmt.Errorf("lego run failed (see output above): %w", err)
	}

	// Resolve absolute cert/key paths for the Apache config. lego writes the
	// certificate (.crt) and private key (.key) under <path>/certificates, plus
	// -- because of --pem -- the two concatenated as .pem. cactus-cli reads the
	// first CERTIFICATE block, so the .pem works as its input as-is.
	certDir, err := filepath.Abs(filepath.Join(certPath, "certificates"))
	if err != nil {
		return fmt.Errorf("resolving cert dir: %w", err)
	}
	certFile := filepath.Join(certDir, domain+".crt")
	keyFile := filepath.Join(certDir, domain+".key")
	pemFile := filepath.Join(certDir, domain+".pem")
	for _, f := range []string{certFile, keyFile, pemFile} {
		if _, err := os.Stat(f); err != nil {
			return fmt.Errorf("expected cert artifact missing: %s", f)
		}
	}
	logStep("Certificate written under %s", certDir)

	// 2. Create a document root with a basic hello-world page.
	var hostDocRoot string
	if _, err := os.Stat("/var/www"); err == nil {
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

	// 3. Convert the standalone cert into its landmark-relative form if requested.
	certToUse := certFile
	if relative {
		if logURL == "" {
			log.Printf("==> warning: --relative requested but -log URL is empty; using standalone certificate")
		} else {
			inputPem := pemFile
			if tai {
				withPropsFile, err := prepareTAIInput(pemFile, certDir, domain)
				if err != nil {
					log.Printf("==> warning: failed to attach TAI properties: %v", err)
				} else {
					inputPem = withPropsFile
					logStep("Standalone cert with TAI properties written to %s", withPropsFile)
				}
			}

			lrFile := filepath.Join(certDir, domain+"-landmark-relative.pem")
			if err := landmarkRelative(cli, inputPem, logURL, lrFile, landmarkWait); err != nil {
				log.Printf("==> warning: no landmark-relative certificate written: %v; using standalone certificate", err)
			} else {
				certToUse = lrFile
			}
		}
	}

	// 4. Write Apache VirtualHost config (<domain>.conf)
	confName := domain + ".conf"

	if _, err := os.Stat("/etc/apache2/sites-available"); err == nil {
		// Standard non-Docker VM with host Apache installed
		confPath := filepath.Join("/etc/apache2/sites-available", confName)
		logStep("Writing Apache config %s (using certificate %s)", confPath, certToUse)
		if err := sudoWriteFile(confPath, vhostConf(domain, hostDocRoot, certToUse, keyFile)); err != nil {
			return fmt.Errorf("writing apache config: %w", err)
		}
		if _, err := exec.LookPath("a2ensite"); err == nil {
			logStep("Enabling mod_ssl and site %s", confName)
			_ = sudoRun("a2enmod", "ssl")
			_ = sudoRun("a2ensite", confName)
			logStep("Validating Apache configuration")
			if err := sudoRun("apache2ctl", "configtest"); err == nil {
				logStep("Reloading Apache")
				_ = sudoRun("systemctl", "reload-or-restart", "apache2")
			}
		}
	} else {
		// Docker-based setup
		relCert, err := filepath.Rel(certDir, certToUse)
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
		logStep("Writing Apache config %s (container cert %s)", confPath, containerCertPath)
		if err := os.WriteFile(confPath, []byte(vhostConf(domain, containerDocRoot, containerCertPath, containerKeyPath)), 0644); err != nil {
			return fmt.Errorf("writing apache config: %w", err)
		}
		logStep("Reloading Apache in Docker container (cactus-apache-1)")
		reloadCmd := exec.Command("docker", "exec", "cactus-apache-1", "httpd", "-k", "graceful")
		reloadCmd.Stdout = os.Stdout
		reloadCmd.Stderr = os.Stderr
		if err := reloadCmd.Run(); err != nil {
			log.Printf("==> warning: failed to reload Apache container: %v", err)
		} else {
			logStep("Apache container reloaded successfully.")
		}
	}

	logStep("Done. Certificate for %s is ready.", domain)
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

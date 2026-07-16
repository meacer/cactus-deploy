// requestmtc.go requests a MTC certificate for a domain from a (local, e.g.
// Pebble) ACME server via lego, then configures Apache to serve a small
// hello-world site for that domain over HTTPS with an HTTP->HTTPS redirect.
// Finally it converts the issued standalone certificate into its
// landmark-relative form (draft §6.3.3) via cactus-cli.
//
// Each domain gets its OWN Apache config file at
// /etc/apache2/sites-available/mtc-<domain>.conf which is enabled with a2ensite.
// It never writes to the shared mtc.conf, so existing sites are left untouched.
//
// Usage:
//
//	go run requestmtc.go -domain example.test
//	go run requestmtc.go -domain example.test -email me@example.com
//	go run requestmtc.go -domain example.test -log https://ca1.test.mtcs.dev/1
//	go run requestmtc.go -domain example.test -log ""   # skip the landmark-relative step
//
// Privileged steps (writing under /etc/apache2 and /var/www, reloading Apache)
// are run via sudo, so you may be prompted for your password.
package main

import (
	"bytes"
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
	logURL := flag.String("log", "http://localhost:14080/1", "cactus log URL (monitoring endpoint + log number) used to build the landmark-relative cert; empty to skip that step")
	cli := flag.String("cactus-cli", "cactus-cli", "path to the cactus-cli binary")
	landmarkWait := flag.Duration("landmark-wait", 90*time.Second, "how long to wait for a landmark covering the freshly issued entry")
	flag.Parse()

	if *domain == "" {
		fmt.Fprintln(os.Stderr, "error: -domain is required")
		flag.Usage()
		os.Exit(1)
	}

	if err := run(*domain, *email, *server, *certPath, *logURL, *cli, *landmarkWait); err != nil {
		log.Fatalf("error: %v", err)
	}
}

func run(domain, email, server, certPath, logURL, cli string, landmarkWait time.Duration) error {
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
	docRoot := filepath.Join("/var/www", domain)
	logStep("Creating document root %s", docRoot)
	if err := sudoRun("mkdir", "-p", docRoot); err != nil {
		return fmt.Errorf("creating docroot: %w", err)
	}
	indexPath := filepath.Join(docRoot, "index.html")
	if err := sudoWriteFile(indexPath, indexHTML(domain)); err != nil {
		return fmt.Errorf("writing index.html: %w", err)
	}
	logStep("Hello world page written to %s", indexPath)

	// 3. Write this domain's OWN Apache config (never the shared mtc.conf).
	confName := "mtc-" + domain + ".conf"
	confPath := filepath.Join("/etc/apache2/sites-available", confName)
	logStep("Writing Apache config %s", confPath)
	if err := sudoWriteFile(confPath, vhostConf(domain, docRoot, certFile, keyFile)); err != nil {
		return fmt.Errorf("writing apache config: %w", err)
	}

	// 4. Enable the site and (re)load Apache.
	logStep("Enabling mod_ssl and site %s", confName)
	if err := sudoRun("a2enmod", "ssl"); err != nil {
		return fmt.Errorf("a2enmod ssl: %w", err)
	}
	if err := sudoRun("a2ensite", confName); err != nil {
		return fmt.Errorf("a2ensite %s: %w", confName, err)
	}
	logStep("Validating Apache configuration")
	if err := sudoRun("apache2ctl", "configtest"); err != nil {
		return fmt.Errorf("apache configtest failed: %w", err)
	}
	logStep("Reloading Apache")
	if err := sudoRun("systemctl", "reload-or-restart", "apache2"); err != nil {
		return fmt.Errorf("reloading apache: %w", err)
	}

	// 5. Convert the standalone cert into its landmark-relative form. This runs
	// last because it can block for a landmark interval, and the site is
	// already serving by this point. A failure here is reported but not fatal:
	// the standalone cert Apache is using is unaffected.
	if logURL != "" {
		lrFile := filepath.Join(certDir, domain+"-landmark-relative.pem")
		if err := landmarkRelative(cli, pemFile, logURL, lrFile, landmarkWait); err != nil {
			log.Printf("==> warning: no landmark-relative certificate written: %v", err)
		}
	}

	logStep("Done. https://%s/ is now served.", domain)
	return nil
}

// landmarkRelative converts the standalone certificate at certFile into its
// landmark-relative form (§6.3.3) with `cactus-cli cert landmark-relative`,
// writing the PEM the command prints on stdout to outFile.
//
// A freshly issued entry is not covered by a landmark until the next one is
// allocated, and until then the conversion fails by design. So retry that one
// error until a landmark shows up or wait elapses; any other failure is real
// and returned immediately.
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
			// cactus-cli reports the landmark, subtree and proof size on
			// stderr; it's the useful summary of what was just built.
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

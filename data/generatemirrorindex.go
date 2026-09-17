// generatemirrorindex.go reads cactus-config-docker.json (or a config file passed via -config)
// and generates data/www/mirror1/index.html listing the mirrored CAs and checkpoint URLs.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"html/template"
	"log"
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	Log struct {
		Number int `json:"number"`
	} `json:"log"`
	CACosigner struct {
		ID string `json:"id"`
	} `json:"ca_cosigner"`
	Monitoring struct {
		ExternalURL string `json:"external_url"`
	} `json:"monitoring"`
}

type MirroredLog struct {
	Name          string
	Hash          string
	MonitoringURL string
	CheckpointURL string
}

type IndexData struct {
	Logs    []MirroredLog
	VKeyPEM string
	VKeySHA string
}

var spkiPrefixMLDSA44 = []byte{
	0x30, 0x82, 0x05, 0x32, 0x30, 0x0b, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
	0x65, 0x03, 0x04, 0x03, 0x11, 0x03, 0x82, 0x05, 0x21, 0x00,
}

func formatSPKIPEM(keyPEM []byte) (string, string, error) {
	block, _ := pem.Decode(keyPEM)
	if block == nil || block.Type != "PUBLIC KEY" {
		return "", "", fmt.Errorf("failed to decode PEM public key")
	}
	der := block.Bytes
	if len(der) == 1312 {
		der = append(spkiPrefixMLDSA44, der...)
	}
	hash := sha256.Sum256(der)
	shaHex := hex.EncodeToString(hash[:])
	spkiPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "PUBLIC KEY",
		Bytes: der,
	})
	return strings.TrimSpace(string(spkiPEM)), shaHex, nil
}

const htmlTemplate = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Test MTC Mirror</title>
  <style>
    body { font-family: system-ui, -apple-system, sans-serif; margin: 2rem; line-height: 1.5; color: #222; max-width: 800px; }
    h1 { color: #1a73e8; border-bottom: 2px solid #e8eaed; padding-bottom: 0.5rem; }
    h2 { color: #1a73e8; margin-top: 2rem; }
    ul { list-style-type: none; padding: 0; }
    li { background: #f8f9fa; border: 1px solid #dadce0; border-radius: 8px; padding: 1rem 1.25rem; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
    a { color: #1a73e8; font-weight: 600; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .hash { font-family: monospace; font-size: 0.85rem; color: #5f6368; word-break: break-all; margin-top: 0.25rem; }
    .item-title { font-size: 1.05rem; margin-bottom: 0.25rem; }
    pre { background: #f8f9fa; border: 1px solid #dadce0; border-radius: 8px; padding: 1rem; overflow-x: auto; font-family: monospace; font-size: 0.85rem; }
  </style>
</head>
<body>
  <h1>Test MTC Mirror</h1>
  <p>Mirrored Certificate Transparency Logs:</p>
  <ul>
  {{range .Logs}}
    <li>
      <div class="item-title"><a href="{{.MonitoringURL}}">{{.Name}}</a></div>
      <div class="hash">Hash: {{.Hash}}</div>
      <div style="margin-top: 0.5rem;"><a href="{{.CheckpointURL}}">Checkpoint URL</a></div>
    </li>
  {{else}}
    <li>No mirrored logs found.</li>
  {{end}}
  </ul>
  {{if .VKeyPEM}}
  <h2>Sunlight Mirror Public Key (SPKI PEM)</h2>
  <div class="hash">SPKI SHA-256: {{.VKeySHA}}</div>
  <pre>{{.VKeyPEM}}</pre>
  {{end}}
</body>
</html>
`

func main() {
	configPath := flag.String("config", "data/cactus-config-docker.json", "path to cactus config json")
	outPath := flag.String("out", "out/www/mirror1/index.html", "output index.html path")
	keyPath := flag.String("key", "keys/mirror-cosigner.pem", "path to mirror cosigner PEM key")
	flag.Parse()

	data, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatalf("error reading config file %s: %v", *configPath, err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatalf("error parsing config json: %v", err)
	}

	origin := fmt.Sprintf("oid/1.3.6.1.4.1.%s.0.%d", cfg.CACosigner.ID, cfg.Log.Number)
	hashBytes := sha256.Sum256([]byte(origin))
	hashHex := hex.EncodeToString(hashBytes[:])

	monitoringURL := "https://ca1.test.mtcs.dev"

	logs := []MirroredLog{
		{
			Name:          origin,
			Hash:          hashHex,
			MonitoringURL: monitoringURL,
			CheckpointURL: fmt.Sprintf("/mirror/%s/checkpoint", hashHex),
		},
	}

	var vkeyPEM, vkeySHA string
	if keyBytes, err := os.ReadFile(*keyPath); err == nil {
		pemStr, shaHex, err := formatSPKIPEM(keyBytes)
		if err != nil {
			log.Printf("warning: failed to format PEM from %s: %v", *keyPath, err)
		} else {
			vkeyPEM = pemStr
			vkeySHA = shaHex
		}
	} else {
		log.Printf("warning: could not read key file %s: %v", *keyPath, err)
	}

	indexData := IndexData{
		Logs:    logs,
		VKeyPEM: vkeyPEM,
		VKeySHA: vkeySHA,
	}

	tmpl, err := template.New("index").Parse(htmlTemplate)
	if err != nil {
		log.Fatalf("error parsing html template: %v", err)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, indexData); err != nil {
		log.Fatalf("error executing template: %v", err)
	}

	if err := os.MkdirAll(filepath.Dir(*outPath), 0755); err != nil {
		log.Fatalf("error creating output directory: %v", err)
	}

	if err := os.WriteFile(*outPath, buf.Bytes(), 0644); err != nil {
		log.Fatalf("error writing output file: %v", err)
	}

	log.Printf("==> Successfully generated mirror index page at %s for %s (%s)", *outPath, origin, hashHex)
}

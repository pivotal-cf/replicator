package replicator

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"regexp"
	"strings"

	yaml "gopkg.in/yaml.v2"
)

var metadataRegexp = regexp.MustCompile(`metadata\/.*\.yml$`)

const (
	defaultIsoSegName     = "p-isolation-segment"
	defaultRouterJobType  = "isolated_router"
	defaultCellJobType    = "isolated_diego_cell"
	defaultHAProxyJobType = "isolated_ha_proxy"
)

type TileReplicator struct{}

func NewTileReplicator() TileReplicator {
	return TileReplicator{}
}

func (t TileReplicator) Replicate(config ApplicationConfig) error {
	srcTileZip, err := zip.OpenReader(config.Path)
	if err != nil {
		return errors.New("could not open source zip file")
	}
	defer srcTileZip.Close()

	dstTileFile, err := os.Create(config.Output)
	if err != nil {
		return errors.New("could not create destination tile")
	}
	defer dstTileFile.Close()

	dstTileZip := zip.NewWriter(dstTileFile)
	defer dstTileZip.Close()

	for _, srcFile := range srcTileZip.File {
		srcFileReader, err := srcFile.Open()

		if err != nil {
			return err // not tested
		}

		dstFile, err := dstTileZip.Create(srcFile.Name)
		if err != nil {
			return err // not tested
		}

		if metadataRegexp.MatchString(srcFile.Name) {
			contents, err := ioutil.ReadAll(srcFileReader)
			if err != nil {
				return err // not tested
			}

			var metadata Metadata

			if err := yaml.Unmarshal([]byte(contents), &metadata); err != nil {
				return err
			}

			if err := t.replaceName(&metadata, config); err != nil {
				return err
			}

			t.replaceLabel(&metadata, config)

			contentsYaml, err := yaml.Marshal(metadata)
			if err != nil {
				return err // not tested
			}

			finalContents := t.replaceProperties(string(contentsYaml), t.formatName(config))

			_, err = dstFile.Write([]byte(finalContents))
		} else {
			_, err = io.Copy(dstFile, srcFileReader)
		}

		err = srcFileReader.Close()
		if err != nil {
			return err // not tested
		}
	}

	return nil
}

func (TileReplicator) formatName(config ApplicationConfig) string {
	re := regexp.MustCompile("[-_ ]")

	return strings.ToLower(string(re.ReplaceAllLiteralString(config.Name, "_")))
}

func (TileReplicator) replaceProperties(metadata string, name string) string {
	newDiegoCellName := fmt.Sprintf("%s_%s", defaultCellJobType, name)
	newRouterName := fmt.Sprintf("%s_%s", defaultRouterJobType, name)
	newHAProxyName := fmt.Sprintf("%s_%s", defaultHAProxyJobType, name)

	cellReplacedmetadata := strings.Replace(metadata, "isolated_diego_cell", newDiegoCellName, -1)
	cellReplacedmetadata = strings.Replace(cellReplacedmetadata, "isolated_ha_proxy", newHAProxyName, -1)
	return strings.Replace(cellReplacedmetadata, "isolated_router", newRouterName, -1)
}

func (TileReplicator) replaceName(metadata *Metadata, config ApplicationConfig) error {
	if metadata.Name != defaultIsoSegName {
		return fmt.Errorf("the replicator does not replicate %s, supported tiles are [%s]",
			metadata.Name, defaultIsoSegName)
	}

	re := regexp.MustCompile("[-_ ]")
	metadata.Name = defaultIsoSegName + "-" + strings.ToLower(string(re.ReplaceAllLiteralString(config.Name, "-")))

	return nil
}

func (TileReplicator) replaceLabel(metadata *Metadata, config ApplicationConfig) {
	metadata.Label = fmt.Sprintf("%s (%s)", metadata.Label, config.Name)
}

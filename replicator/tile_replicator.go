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

	yaml "go.yaml.in/yaml/v3"
)

var metadataRegexp = regexp.MustCompile(`metadata\/.*\.yml$`)
var supportedTiles = []string{"p-isolation-segment", "p-windows-runtime", "pas-windows"}

const (
	istRouterJobType  = "isolated_router"
	istCellJobType    = "isolated_diego_cell"
	istHAProxyJobType = "isolated_ha_proxy"

	wrtCellJobType = "windows_diego_cell"
)

type TileReplicator struct {
	logger logger
}

//go:generate counterfeiter -o ./fakes/logger.go --fake-name Logger . logger
type logger interface {
	Printf(s string, v ...interface{})
}

func NewTileReplicator(logger logger) TileReplicator {
	return TileReplicator{
		logger: logger,
	}
}

func (t TileReplicator) Replicate(config ApplicationConfig) error {
	t.logger.Printf("replicating %s to %s\n", config.Path, config.Output)

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

		t.logger.Printf("adding: %s\n", srcFile.Name)

		header := &zip.FileHeader{
			Name:   srcFile.Name,
			Method: zip.Deflate,
		}
		header.SetMode(srcFile.Mode())

		dstFile, err := dstTileZip.CreateHeader(header)

		if err != nil {
			return err // not tested
		}

		if metadataRegexp.MatchString(srcFile.Name) {
			contents, err := ioutil.ReadAll(srcFileReader)
			if err != nil {
				return err // not tested
			}

			var metadata map[string]interface{}

			if err := yaml.Unmarshal([]byte(contents), &metadata); err != nil {
				return err
			}

			tileName, ok := metadata["name"]
			if !ok {
				return errors.New("Tile metadata file is missing required tile property 'name'")
			}
			metadata["name"], err = t.replaceName(fmt.Sprintf("%v", tileName), config)
			if err != nil {
				return err
			}

			tileLabel, ok := metadata["label"]
			if !ok {
				return errors.New("Tile metadata file is missing required tile property 'label'")
			}
			metadata["label"] = t.replaceLabel(fmt.Sprintf("%v", tileLabel), config)

			contentsYaml, err := yaml.Marshal(metadata)
			if err != nil {
				return err // not tested
			}

			var finalContents string
			if tileName == "p-isolation-segment" {
				finalContents = t.replaceISTProperties(string(contentsYaml), t.formatName(config))
			} else if tileName == "p-windows-runtime" {
				finalContents = t.replaceWRTProperties(string(contentsYaml), t.formatName(config))
			} else if tileName == "pas-windows" {
				finalContents = t.replaceWRTProperties(string(contentsYaml), t.formatName(config))
			}

			_, err = dstFile.Write([]byte(finalContents))
		} else {
			_, err = io.Copy(dstFile, srcFileReader)
		}

		err = srcFileReader.Close()
		if err != nil {
			return err // not tested
		}
	}

	t.logger.Printf("done\n")

	return nil
}

func (TileReplicator) formatName(config ApplicationConfig) string {
	re := regexp.MustCompile("[-_ ]")

	return strings.ToLower(string(re.ReplaceAllLiteralString(config.Name, "_")))
}

func (TileReplicator) replaceISTProperties(metadata string, name string) string {
	newDiegoCellName := fmt.Sprintf("%s_%s", istCellJobType, name)
	newRouterName := fmt.Sprintf("%s_%s", istRouterJobType, name)
	newHAProxyName := fmt.Sprintf("%s_%s", istHAProxyJobType, name)

	cellReplacedMetadata := strings.Replace(metadata, "isolated_diego_cell", newDiegoCellName, -1)
	cellReplacedMetadata = strings.Replace(cellReplacedMetadata, "isolated_ha_proxy", newHAProxyName, -1)
	return strings.Replace(cellReplacedMetadata, "isolated_router", newRouterName, -1)
}

func (TileReplicator) replaceWRTProperties(metadata string, name string) string {
	newDiegoCellName := fmt.Sprintf("%s_%s", wrtCellJobType, name)

	return strings.Replace(metadata, "windows_diego_cell", newDiegoCellName, -1)
}

func (TileReplicator) replaceName(originalName string, config ApplicationConfig) (string, error) {

	re := regexp.MustCompile("[-_ ]")
	for _, supportedTile := range supportedTiles {
		if originalName == supportedTile {
			return originalName + "-" + strings.ToLower(string(re.ReplaceAllLiteralString(config.Name, "-"))), nil
		}
	}

	return "", fmt.Errorf("the replicator does not replicate %s, supported tiles are %s",
		originalName, supportedTiles)

}

func (TileReplicator) replaceLabel(originalLabel string, config ApplicationConfig) string {
	return fmt.Sprintf("%s (%s)", originalLabel, config.Name)
}

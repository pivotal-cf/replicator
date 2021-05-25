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

type TileReplicator struct {
	logger logger
}

type Metadata map[string]interface{}

type JobType struct {
	Name string
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

			var metadata Metadata

			if err := yaml.Unmarshal([]byte(contents), &metadata); err != nil {
				return err
			}

			tileName, ok := metadata["name"]
			if !ok {
				return errors.New("tile metadata file is missing required tile property 'name'")
			}
			metadata["name"], err = t.replaceName(fmt.Sprintf("%v", tileName), config)
			if err != nil {
				return err
			}

			tileLabel, ok := metadata["label"]
			if !ok {
				return errors.New("tile metadata file is missing required tile property 'label'")
			}
			metadata["label"] = t.replaceLabel(fmt.Sprintf("%v", tileLabel), config)

			jobTypesYaml, err := yaml.Marshal(metadata["job_types"])
			if err != nil {
				return err // not tested
			}

			jobTypes, err := t.findJobTypes(jobTypesYaml)
			if err != nil {
				return err // not tested
			}

			contentsYaml, err := yaml.Marshal(metadata)
			if err != nil {
				return err // not tested
			}

			finalContents := string(contentsYaml)

			for _, v := range jobTypes {
				finalContents = t.replaceProperty(finalContents, v.Name, t.formatName(config))
			}

			_, err = dstFile.Write([]byte(finalContents))
			if err != nil {
				return err // not tested
			}
		} else {
			_, err = io.Copy(dstFile, srcFileReader)
			if err != nil {
				return err // not tested
			}
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

func (TileReplicator) findJobTypes(j []byte) ([]JobType, error) {
	var job_types []JobType

	if err := yaml.Unmarshal(j, &job_types); err != nil {
		return nil, err
	}

	return job_types, nil
}

func (t TileReplicator) replaceProperty(metadata string, name string, suffix string) string {
	newPropertyName := fmt.Sprintf("%s_%s", name, suffix)
	t.logger.Printf("updating job: %s => %s", name, newPropertyName)

	return strings.Replace(metadata, name, newPropertyName, -1)
}

func (TileReplicator) replaceName(originalName string, config ApplicationConfig) (string, error) {
	re := regexp.MustCompile("[-_ ]")
	return originalName + "-" + strings.ToLower(string(re.ReplaceAllLiteralString(config.Name, "-"))), nil
}

func (TileReplicator) replaceLabel(originalLabel string, config ApplicationConfig) string {
	return fmt.Sprintf("%s (%s)", originalLabel, config.Name)
}

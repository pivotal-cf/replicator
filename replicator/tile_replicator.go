package replicator

import (
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"os"
	"regexp"

	yaml "gopkg.in/yaml.v2"
)

var metadataRegexp = regexp.MustCompile(`metadata\/.*\.yml$`)

var ymlRegexp = regexp.MustCompile(`.*\.yml$`)
var defaultIsoSegNamePrefix = "p-isolation-segment"
var defaultIsoSegCellNamePrefix = ".isolated_diego_cell"

// var defaultIsoSegRouterNamePrefix = ".isolated_router"

type TileReplicator struct{}

func NewTileReplicator() TileReplicator {
	return TileReplicator{}
}

type Metadata struct {
	Name                     string
	Releases                 []interface{}
	StemcellCriteria         interface{}
	Description              string
	FormTypes                []interface{} `yaml:"form_types"`
	IconImage                string        `yaml:"icon_image"`
	InstallTimeVerifiers     interface{}   `yaml:"install_time_verifiers"`
	JobTypes                 []interface{} `yaml:"job_types"`
	Label                    string
	MetadataVersion          string        `yaml:"metadata_version"`
	MinimumVersionForUpgrade string        `yaml:"minimum_version_for_upgrade"`
	PostDeployErrands        []interface{} `yaml:"post_deploy_errands"`
	ProductVersion           string        `yaml:"product_version"`
	PropertyBlueprints       []interface{} `yaml:"property_blueprints"`
	ProvidesProductVersions  []interface{} `yaml:"provides_product_versions"`
	Rank                     int
	RequiresProductVersions  []interface{} `yaml:"requires_product_versions"`
	Serial                   bool
}

func (TileReplicator) Replicate(config ApplicationConfig) error {
	// open the tile
	srcTileZip, err := zip.OpenReader(config.Path)
	if err != nil {
		panic(err)
	}
	defer srcTileZip.Close()

	// create the new tile
	dstTileFile, err := os.Create(config.Output)
	if err != nil {
		panic(err)
	}
	defer dstTileFile.Close()

	// create the new tile zipper
	dstTileZip := zip.NewWriter(dstTileFile)
	defer dstTileZip.Close()

	// for each file in the tile copy it to the new tile, expect modify tile metadata *.yml
	for _, srcFile := range srcTileZip.File {

		// open the srcFile to read contents
		srcFileReader, err := srcFile.Open()
		if err != nil {
			panic(err)
		}

		// create the file in the destination zip file
		dstFile, err := dstTileZip.Create(srcFile.Name)
		if err != nil {
			panic(err)
		}

		if metadataRegexp.MatchString(srcFile.Name) {
			buf := new(bytes.Buffer)

			_, err = buf.ReadFrom(srcFileReader)
			if err != nil {
				panic(err)
			}

			contents := buf.Bytes()

			var metadata Metadata
			yaml.Unmarshal(contents, &metadata)

			metadata.Name = defaultIsoSegNamePrefix + "-" + config.Name

			contentsYaml, err := yaml.Marshal(metadata)
			if err != nil {
				panic(err)
			}
			_, err = dstFile.Write(contentsYaml)
		} else {
			// copy srcFile contents to destination
			_, err = io.Copy(dstFile, srcFileReader)
		}

		// close the srcFile
		err = srcFileReader.Close()
		if err != nil {
			panic(err)
		}
	}

	fmt.Println(config.Output)

	return nil
}

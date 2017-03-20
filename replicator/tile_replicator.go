package replicator

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"regexp"
)

var metadataRegexp = regexp.MustCompile(`metadata\/.*\.yml$`)

type TileReplicator struct{}

func NewTileReplicator() TileReplicator {
	return TileReplicator{}
}

type Metadata struct {
	Name                     string
	Releases                 []interface{}
	StemcellCriteria         interface{}
	Description              string
	FormType                 []string
	IconImage                string
	InstallTimeVerifiers     interface{}
	JobTypes                 []interface{}
	Label                    string
	MetadataVersion          string
	MinimumVersionForUpgrade string
	PostDeployErrands        []interface{}
	ProductVersion           string
	PropertyBlueprints       []interface{}
	ProvidesProductVersions  []interface{}
	Rank                     int
	RequiresProductVersions  []interface{}
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

		// copy srcFile contents to destination
		_, err = io.Copy(dstFile, srcFileReader)
		if err != nil {
			panic(err)
		}

		// close the srcFile
		err = srcFileReader.Close()
		if err != nil {
			panic(err)
		}

		// if metadataRegexp.MatchString(srcFile.Name) {
		// 	continue
		// }
	}

	fmt.Println(config.Output)

	return nil
}

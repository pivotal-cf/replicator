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

func (t TileReplicator) Replicate(config ApplicationConfig) error {
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

			t.findAndReplaceJobTypeName(metadata.JobTypes, "isolated_router", fmt.Sprintf("isolated_router_%s", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, ".isolated_router.static_ips",
				fmt.Sprintf(".isolated_router_%s.static_ips", config.Name))

			t.findAndReplaceJobTypeName(metadata.JobTypes, "isolated_diego_cell", fmt.Sprintf("isolated_diego_cell_%s", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, ".isolated_diego_cell.insecure_docker_registry_list",
				fmt.Sprintf(".isolated_diego_cell_%s.insecure_docker_registry_list", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, ".isolated_diego_cell.placement_tag",
				fmt.Sprintf(".isolated_diego_cell_%s.placement_tag", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, ".isolated_diego_cell.garden_network_pool",
				fmt.Sprintf(".isolated_diego_cell_%s.garden_network_pool", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, ".isolated_diego_cell.garden_network_mtu",
				fmt.Sprintf(".isolated_diego_cell_%s.garden_network_mtu", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, ".isolated_diego_cell.executor_memory_capacity",
				fmt.Sprintf(".isolated_diego_cell_%s.executor_memory_capacity", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, ".isolated_diego_cell.executor_disk_capacity",
				fmt.Sprintf(".isolated_diego_cell_%s.executor_disk_capacity", config.Name))

			contentsYaml, err := yaml.Marshal(metadata)
			if err != nil {
				panic(err)
			}

			// contentsYamlStr := strings.Replace(string(contentsYaml), "isolated_diego_cell", "isolated_diego_cell_"+config.Name, -1)
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

	return nil
}

func (TileReplicator) findAndReplaceFormTypeRef(formTypes []*FormType, ref, replacementRef string) bool {
	formIndex := -1
	inputIndex := -1

	for i, formType := range formTypes {
		for j, input := range formType.PropertyInputs {
			if input.Reference == ref {
				formIndex = i
				inputIndex = j
				break
			}
		}
	}

	if formIndex == -1 || inputIndex == -1 {
		return false
	}

	formTypes[formIndex].PropertyInputs[inputIndex].Reference = replacementRef
	return true
}

func (TileReplicator) findAndReplaceJobTypeName(jobTypes []*JobType, name, replacementName string) bool {
	jobTypeIndex := -1

	for i, jobType := range jobTypes {
		if jobType.Name == name {
			jobTypeIndex = i
			break
		}
	}

	if jobTypeIndex == -1 {
		return false
	}

	jobTypes[jobTypeIndex].Name = replacementName
	return true
}

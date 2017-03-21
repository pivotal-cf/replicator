package replicator

import (
	"archive/zip"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"regexp"

	yaml "gopkg.in/yaml.v2"
)

var metadataRegexp = regexp.MustCompile(`metadata\/.*\.yml$`)

const (
	defaultIsoSegName      = "p-isolation-segment"
	defaultRouterJobType   = "isolated_router"
	defaultRouterStaticIPs = ".isolated_router.static_ips"

	defaultCellJobType                           = "isolated_diego_cell"
	defaultCellDockerFormTypeRef                 = ".isolated_diego_cell.insecure_docker_registry_list"
	defaultCellPlacementTagFormTypeRef           = ".isolated_diego_cell.placement_tag"
	defaultCellGardenNetworkPoolFormTypeRef      = ".isolated_diego_cell.garden_network_pool"
	defaultCellGardenNetworkMTUFormTypeRef       = ".isolated_diego_cell.garden_network_mtu"
	defaultCellExecutorMemoryCapacityFormTypeRef = ".isolated_diego_cell.executor_memory_capacity"
	defaultCellExecutorDiskCapacityFormTypeRef   = ".isolated_diego_cell.executor_disk_capacity"
)

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
			contents, err := ioutil.ReadAll(srcFileReader)
			if err != nil {
				panic(err)
			}

			var metadata Metadata
			if err := yaml.Unmarshal(contents, &metadata); err != nil {
				panic(err)
			}

			metadata.Name = defaultIsoSegName + "-" + config.Name

			t.findAndReplaceJobTypeName(metadata.JobTypes, "isolated_router", fmt.Sprintf("isolated_router_%s", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, defaultRouterStaticIPs,
				fmt.Sprintf(".isolated_router_%s.static_ips", config.Name))

			t.findAndReplaceJobTypeName(metadata.JobTypes, defaultCellJobType, fmt.Sprintf("%s_%s", defaultCellJobType, config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, defaultCellDockerFormTypeRef,
				fmt.Sprintf(".isolated_diego_cell_%s.insecure_docker_registry_list", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, defaultCellPlacementTagFormTypeRef,
				fmt.Sprintf(".isolated_diego_cell_%s.placement_tag", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, defaultCellGardenNetworkPoolFormTypeRef,
				fmt.Sprintf(".isolated_diego_cell_%s.garden_network_pool", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, defaultCellGardenNetworkMTUFormTypeRef,
				fmt.Sprintf(".isolated_diego_cell_%s.garden_network_mtu", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, defaultCellExecutorMemoryCapacityFormTypeRef,
				fmt.Sprintf(".isolated_diego_cell_%s.executor_memory_capacity", config.Name))
			t.findAndReplaceFormTypeRef(metadata.FormTypes, defaultCellExecutorDiskCapacityFormTypeRef,
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

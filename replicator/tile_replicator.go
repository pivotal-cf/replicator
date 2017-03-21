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
	srcTileZip, err := zip.OpenReader(config.Path)
	if err != nil {
		panic(err)
	}
	defer srcTileZip.Close()

	dstTileFile, err := os.Create(config.Output)
	if err != nil {
		panic(err)
	}
	defer dstTileFile.Close()

	dstTileZip := zip.NewWriter(dstTileFile)
	defer dstTileZip.Close()

	for _, srcFile := range srcTileZip.File {
		srcFileReader, err := srcFile.Open()
		if err != nil {
			panic(err)
		}

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

			metadata.RenameJob("isolated_router", fmt.Sprintf("isolated_router_%s", config.Name))
			metadata.RenameFormTypeRef(defaultRouterStaticIPs, fmt.Sprintf(".isolated_router_%s.static_ips", config.Name))

			metadata.RenameJob(defaultCellJobType, fmt.Sprintf("%s_%s", defaultCellJobType, config.Name))
			metadata.RenameFormTypeRef(defaultCellDockerFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.insecure_docker_registry_list", config.Name))
			metadata.RenameFormTypeRef(defaultCellPlacementTagFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.placement_tag", config.Name))
			metadata.RenameFormTypeRef(defaultCellGardenNetworkPoolFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.garden_network_pool", config.Name))
			metadata.RenameFormTypeRef(defaultCellGardenNetworkMTUFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.garden_network_mtu", config.Name))
			metadata.RenameFormTypeRef(defaultCellExecutorMemoryCapacityFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.executor_memory_capacity", config.Name))
			metadata.RenameFormTypeRef(defaultCellExecutorDiskCapacityFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.executor_disk_capacity", config.Name))

			contentsYaml, err := yaml.Marshal(metadata)
			if err != nil {
				panic(err)
			}

			_, err = dstFile.Write(contentsYaml)
		} else {
			_, err = io.Copy(dstFile, srcFileReader)
		}

		err = srcFileReader.Close()
		if err != nil {
			panic(err)
		}
	}

	return nil
}

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
	defaultCellDNSServersFormTypeRef             = ".isolated_diego_cell.dns_servers"
	defaultCellSilkDaemonClientCertFormTypeRef   = ".isolated_diego_cell.silk_daemon_client_cert"
	defaultCellNetworkPolicyAgentCertFormTypeRef = ".isolated_diego_cell.network_policy_agent_cert"
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
			if err := yaml.Unmarshal(contents, &metadata); err != nil {
				return err
			}

			if err := t.renameMetadata(&metadata, config); err != nil {
				return err // not tested
			}

			contentsYaml, err := yaml.Marshal(metadata)
			if err != nil {
				return err // not tested
			}

			_, err = dstFile.Write(contentsYaml)
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

func (TileReplicator) renameMetadata(metadata *Metadata, config ApplicationConfig) error {
	if metadata.Name != defaultIsoSegName {
		return fmt.Errorf("the replicator does not replicate %s, supported tiles are [%s]",
			metadata.Name, defaultIsoSegName)
	}

	metadata.Label = fmt.Sprintf("%s (%s)", metadata.Label, config.Name)
	re := regexp.MustCompile("[-_ ]")

	metadata.Name = defaultIsoSegName + "-" + strings.ToLower(string(re.ReplaceAllLiteralString(config.Name, "-")))

	jobPropertyName := strings.ToLower(string(re.ReplaceAllLiteralString(config.Name, "_")))

	err := metadata.RenameJob(defaultRouterJobType, fmt.Sprintf("isolated_router_%s", jobPropertyName))
	if err != nil {
		return err //not tested
	}

	metadata.RenameFormTypeRef(defaultRouterStaticIPs, fmt.Sprintf(".isolated_router_%s.static_ips", jobPropertyName))

	err = metadata.RenameJob(defaultCellJobType, fmt.Sprintf("%s_%s", defaultCellJobType, jobPropertyName))
	if err != nil {
		return err //not tested
	}

	metadata.RenameFormTypeRef(defaultCellDockerFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.insecure_docker_registry_list", jobPropertyName))
	metadata.RenameFormTypeRef(defaultCellPlacementTagFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.placement_tag", jobPropertyName))
	metadata.RenameFormTypeRef(defaultCellGardenNetworkPoolFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.garden_network_pool", jobPropertyName))
	metadata.RenameFormTypeRef(defaultCellGardenNetworkMTUFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.garden_network_mtu", jobPropertyName))
	metadata.RenameFormTypeRef(defaultCellExecutorMemoryCapacityFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.executor_memory_capacity", jobPropertyName))
	metadata.RenameFormTypeRef(defaultCellExecutorDiskCapacityFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.executor_disk_capacity", jobPropertyName))
	metadata.RenameFormTypeRef(defaultCellDNSServersFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.dns_servers", jobPropertyName))
	metadata.RenameFormTypeRef(defaultCellSilkDaemonClientCertFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.silk_daemon_client_cert", jobPropertyName))
	metadata.RenameFormTypeRef(defaultCellNetworkPolicyAgentCertFormTypeRef, fmt.Sprintf(".isolated_diego_cell_%s.network_policy_agent_cert", jobPropertyName))

	return nil
}

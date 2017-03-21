package replicator_test

import (
	"archive/zip"
	"io/ioutil"
	"path/filepath"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	gomegamatchers "github.com/pivotal-cf-experimental/gomegamatchers"
	"github.com/pivotal-cf/replicator/replicator"
)

var _ = Describe("tile replicator", func() {
	var (
		tileReplicator replicator.TileReplicator

		pathToTile       string
		pathToOutputTile string
		expectedMetadata string
	)

	Describe("Replicate", func() {
		BeforeEach(func() {
			pathToTile = filepath.Join("fixtures", "some-tile.pivotal")

			tempDir, err := ioutil.TempDir("", "")
			Expect(err).NotTo(HaveOccurred())
			pathToOutputTile = filepath.Join(tempDir, "some-other-tile.pivotal")

			expectedMetadataFile := filepath.Join("fixtures", "expected-metadata.yml")

			contents, err := ioutil.ReadFile(expectedMetadataFile)
			Expect(err).NotTo(HaveOccurred())
			expectedMetadata = string(contents)

			tileReplicator = replicator.NewTileReplicator()
		})

		It("creates a duplicate tile with modified metadata", func() {
			err := tileReplicator.Replicate(replicator.ApplicationConfig{
				Path:   pathToTile,
				Output: pathToOutputTile,
				Name:   "magenta",
			})
			Expect(err).NotTo(HaveOccurred())

			zr, err := zip.OpenReader(pathToOutputTile)
			Expect(err).NotTo(HaveOccurred())

			defer zr.Close()

			var metadata *zip.File
			for _, file := range zr.File {
				if file.Name == "metadata/some-product.yml" {
					metadata = file
					break
				}
			}
			Expect(metadata).NotTo(BeNil())

			f, err := metadata.Open()
			Expect(err).NotTo(HaveOccurred())

			contents, err := ioutil.ReadAll(f)
			Expect(err).NotTo(HaveOccurred())

			Expect(string(contents)).To(gomegamatchers.MatchYAML(expectedMetadata))
		})
	})
})

package replicator_test

import (
	"archive/zip"
	"io/ioutil"
	"path/filepath"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	"github.com/pivotal-cf-experimental/gomegamatchers"
	"github.com/pivotal-cf/replicator/replicator"
)

var _ = Describe("tile replicator", func() {
	var (
		tileReplicator replicator.TileReplicator

		pathToTile                  string
		pathToAlreadyDuplicatedTile string
		pathToInvalidYamlMetadata   string
		pathToOutputTile            string
		expectedMetadata            string
	)

	Describe("Replicate", func() {
		Context("when replicating the isolation segment tile", func() {
			BeforeEach(func() {
				pathToTile = filepath.Join("..", "fixtures", "ist.pivotal")
				pathToAlreadyDuplicatedTile = filepath.Join("..", "fixtures", "ist-duplicated.pivotal")
				pathToInvalidYamlMetadata = filepath.Join("..", "fixtures", "invalid-metadata.pivotal")

				tempDir, err := ioutil.TempDir("", "")
				Expect(err).NotTo(HaveOccurred())
				pathToOutputTile = filepath.Join(tempDir, "replicated-tile.pivotal")

				expectedMetadataFile := filepath.Join("..", "fixtures", "expected-ist-metadata.yml")

				contents, err := ioutil.ReadFile(expectedMetadataFile)
				Expect(err).NotTo(HaveOccurred())
				expectedMetadata = string(contents)

				tileReplicator = replicator.NewTileReplicator()
			})

			It("creates a duplicate tile with modified metadata", func() {
				err := tileReplicator.Replicate(replicator.ApplicationConfig{
					Path:   pathToTile,
					Output: pathToOutputTile,
					Name:   "Magenta Foo",
				})
				Expect(err).NotTo(HaveOccurred())

				zr, err := zip.OpenReader(pathToOutputTile)
				Expect(err).NotTo(HaveOccurred())

				defer zr.Close()

				var metadata *zip.File
				for _, file := range zr.File {
					if file.Name == "metadata/p-isolation-segment.yml" {
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

			Context("when a property does not exist in the tile metadata", func() {
				It("does not fail to replicate the tile", func() {
					pathToTile = filepath.Join("..", "fixtures", "some-tile-with-missing-property.pivotal")
					expectedMetadataFile := filepath.Join("..", "fixtures", "expected-metadata-with-missing-property.yml")
					contents, err := ioutil.ReadFile(expectedMetadataFile)
					Expect(err).NotTo(HaveOccurred())
					expectedMetadata = string(contents)

					err = tileReplicator.Replicate(replicator.ApplicationConfig{
						Path:   pathToTile,
						Output: pathToOutputTile,
						Name:   "Magenta Foo",
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

					contents, err = ioutil.ReadAll(f)
					Expect(err).NotTo(HaveOccurred())

					Expect(string(contents)).To(gomegamatchers.MatchYAML(expectedMetadata))
				})
			})

			Context("error handling", func() {
				Context("when the source tile is not supported", func() {
					It("returns an error", func() {
						err := tileReplicator.Replicate(replicator.ApplicationConfig{
							Path:   pathToAlreadyDuplicatedTile,
							Output: pathToOutputTile,
							Name:   "Magenta Foo",
						})

						Expect(err).To(MatchError("the replicator does not replicate " +
							"p-isolation-segment-already-duplicated, supported tiles are " +
							"[p-isolation-segment p-windows-runtime]"))
					})
				})

				Context("when the metadata is an invalid yaml file", func() {
					It("returns an error", func() {
						err := tileReplicator.Replicate(replicator.ApplicationConfig{
							Path:   pathToInvalidYamlMetadata,
							Output: pathToOutputTile,
							Name:   "Magenta Foo",
						})

						Expect(err).To(HaveOccurred())
						Expect(err.Error()).To(ContainSubstring("cannot unmarshal"))
					})
				})

				Context("when the source tile cannot be opened", func() {
					It("returns an error", func() {
						err := tileReplicator.Replicate(replicator.ApplicationConfig{
							Path:   "some-bogus-path",
							Output: pathToOutputTile,
							Name:   "Magenta Foo",
						})

						Expect(err).To(MatchError("could not open source zip file"))
					})
				})

				Context("when creating the destination zip file fails", func() {
					It("returns an error", func() {
						err := tileReplicator.Replicate(replicator.ApplicationConfig{
							Path:   pathToTile,
							Output: "",
							Name:   "Magenta Foo",
						})

						Expect(err).To(MatchError("could not create destination tile"))
					})
				})
			})
		})

		Context("when replicating the windows 2012 runtime tile", func() {
			BeforeEach(func() {
				pathToTile = filepath.Join("..", "fixtures", "wrt.pivotal")

				tempDir, err := ioutil.TempDir("", "")
				Expect(err).NotTo(HaveOccurred())
				pathToOutputTile = filepath.Join(tempDir, "replicated-tile.pivotal")

				expectedMetadataFile := filepath.Join("..", "fixtures", "expected-wrt-metadata.yml")

				contents, err := ioutil.ReadFile(expectedMetadataFile)
				Expect(err).NotTo(HaveOccurred())
				expectedMetadata = string(contents)

				tileReplicator = replicator.NewTileReplicator()
			})

			It("creates a duplicate tile with modified metadata", func() {
				err := tileReplicator.Replicate(replicator.ApplicationConfig{
					Path:   pathToTile,
					Output: pathToOutputTile,
					Name:   "Azure Sea",
				})
				Expect(err).NotTo(HaveOccurred())

				zr, err := zip.OpenReader(pathToOutputTile)
				Expect(err).NotTo(HaveOccurred())

				defer zr.Close()

				var metadata *zip.File
				for _, file := range zr.File {
					if file.Name == "metadata/p-windows-runtime.yml" {
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
})

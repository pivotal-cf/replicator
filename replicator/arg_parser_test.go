package replicator_test

import (
	"fmt"
	"io/ioutil"

	"github.com/pivotal-cf/replicator/replicator"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("arg parser", func() {
	var (
		pathToTile string
		argParser  replicator.ArgParser
	)

	Describe("Parse", func() {

		BeforeEach(func() {
			tmpFile, err := ioutil.TempFile("", "cool-tile.pivotal")
			Expect(err).NotTo(HaveOccurred())

			pathToTile = tmpFile.Name()

			argParser = replicator.NewArgParser()
		})

		It("parses cli args into a config", func() {
			config, err := argParser.Parse([]string{"--name", "some_name", "--path", pathToTile, "--output", "/path/to/output.pivotal"})
			Expect(err).NotTo(HaveOccurred())

			Expect(config).To(Equal(replicator.ApplicationConfig{
				Name:   "some_name",
				Path:   pathToTile,
				Output: "/path/to/output.pivotal",
			}))
		})

		Context("error handling", func() {
			Context("when the name is missing", func() {
				It("returns an error", func() {
					_, err := argParser.Parse([]string{
						"--path", pathToTile,
						"--output", "/path/to/output.pivotal",
					})

					Expect(err).To(MatchError("--name is a required argument"))
				})
			})

			Context("when the name is longer than 10 characters", func() {
				It("returns an error", func() {
					invalidName := "$$$isoseg$$$"

					_, err := argParser.Parse([]string{
						"--path", pathToTile,
						"--name", invalidName,
						"--output", "/path/to/output.pivotal",
					})

					Expect(err).To(MatchError("Name cannot be longer than 10 characters"))
				})
			})

			Context("when the name includes illegal special characters", func() {
				It("returns an error", func() {
					invalidName := "$isoseg$"

					_, err := argParser.Parse([]string{
						"--path", pathToTile,
						"--name", invalidName,
						"--output", "/path/to/output.pivotal",
					})

					Expect(err).To(MatchError(fmt.Sprintf("Invalid special characters in name: %s", invalidName)))
				})
			})

			Context("when the path is missing", func() {
				It("returns an error", func() {
					_, err := argParser.Parse([]string{
						"--name", "some-name",
						"--output", "/path/to/output.pivotal",
					})

					Expect(err).To(MatchError("--path is a required argument"))
				})
			})

			Context("when path points to a non existent file", func() {
				It("returns an error", func() {
					_, err := argParser.Parse([]string{"--name", "some-name", "--path", "/some/non/existent/file", "--output", "/path/to/output.pivotal"})
					Expect(err).To(MatchError("stat /some/non/existent/file: no such file or directory"))
				})
			})

			Context("when path points to a non-regular file", func() {
				It("returns an error", func() {
					tmpDir, err := ioutil.TempDir("", "some-dir")
					Expect(err).NotTo(HaveOccurred())

					_, err = argParser.Parse([]string{"--name", "some-name", "--path", tmpDir, "--output", "/path/to/output.pivotal"})
					Expect(err).To(MatchError(fmt.Sprintf("%s is not a regular file", tmpDir)))
				})
			})

			Context("when the output path is missing", func() {
				It("returns an error", func() {
					_, err := argParser.Parse([]string{
						"--name", "some-name",
						"--path", pathToTile,
					})

					Expect(err).To(MatchError("--output is a required argument"))
				})
			})
		})
	})
})

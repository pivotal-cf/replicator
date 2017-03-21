package replicator_test

import (
	"github.com/pivotal-cf/replicator/replicator"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
)

var _ = Describe("arg parser", func() {
	var argParser replicator.ArgParser

	BeforeEach(func() {
		argParser = replicator.NewArgParser()
	})

	It("parses cli args into a config", func() {
		config, err := argParser.Parse([]string{"--name", "some-name", "--path", "/path/to/a/tile.pivotal", "--output", "/path/to/output.pivotal"})
		Expect(err).NotTo(HaveOccurred())

		Expect(config).To(Equal(replicator.ApplicationConfig{
			Name:   "some-name",
			Path:   "/path/to/a/tile.pivotal",
			Output: "/path/to/output.pivotal",
		}))
	})

	Context("error handling", func() {
		Context("when the name is missing", func() {
			It("throws a helpful error", func() {
				_, err := argParser.Parse([]string{
					"--path", "/path/to/a/tile.pivotal",
					"--output", "/path/to/output.pivotal",
				})

				Expect(err).To(MatchError("--name is a required argument"))
			})
		})

		Context("when the path is missing", func() {
			It("throws a helpful error", func() {
				_, err := argParser.Parse([]string{
					"--name", "some-name",
					"--output", "/path/to/output.pivotal",
				})

				Expect(err).To(MatchError("--path is a required argument"))
			})
		})

		Context("when the output path is missing", func() {
			It("throws a helpful error", func() {
				_, err := argParser.Parse([]string{
					"--name", "some-name",
					"--path", "/path/to/a/tile.pivotal",
				})

				Expect(err).To(MatchError("--output is a required argument"))
			})
		})
	})
})

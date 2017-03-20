package replicator_test

import (
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	"github.com/pivotal-cf/replicator/replicator"
	"github.com/pivotal-cf/replicator/replicator/fakes"
)

var _ = Describe("replicator", func() {
	var (
		argParser      *fakes.ArgParser
		tileReplicator *fakes.TileReplicator
		app            replicator.Application
	)

	BeforeEach(func() {
		argParser = &fakes.ArgParser{}
		tileReplicator = &fakes.TileReplicator{}
		app = replicator.NewApplication(argParser, tileReplicator)
	})

	It("parses args", func() {
		err := app.Run([]string{"--path", "/some/tile/path", "--output", "/some/tile/output/path", "--name", "some-name"})
		Expect(err).NotTo(HaveOccurred())

		Expect(argParser.ParseCallCount()).To(Equal(1))
		Expect(argParser.ParseArgsForCall(0)).To(Equal([]string{"--path", "/some/tile/path", "--output", "/some/tile/output/path", "--name", "some-name"}))
	})

	It("replicates the tile", func() {
		argParser.ParseStub = func(_ []string) (replicator.ApplicationConfig, error) {
			return replicator.ApplicationConfig{Path: "/some/tile/path", Output: "/some/tile/output/path", Name: "some-name"}, nil
		}
		err := app.Run([]string{"--path", "/some/tile/path", "--output", "/some/tile/output/path", "--name", "some-name"})
		Expect(err).NotTo(HaveOccurred())

		Expect(tileReplicator.ReplicateCallCount()).To(Equal(1))

		config := tileReplicator.ReplicateArgsForCall(0)
		Expect(config).To(Equal(replicator.ApplicationConfig{Path: "/some/tile/path", Output: "/some/tile/output/path", Name: "some-name"}))
	})

})

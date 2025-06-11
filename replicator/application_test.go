package replicator_test

import (
	"errors"

	"github.com/pivotal-cf/replicator/replicator"
	"github.com/pivotal-cf/replicator/replicator/fakes"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
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

	Describe("Run", func() {
		It("parses args", func() {
			err := app.Run([]string{"--path", "/some/tile/path", "--output", "/some/tile/output/path", "--name", "some-name"})
			Expect(err).NotTo(HaveOccurred())

			Expect(argParser.ParseCallCount()).To(Equal(1))
			Expect(argParser.ParseArgsForCall(0)).To(Equal([]string{"--path", "/some/tile/path", "--output", "/some/tile/output/path", "--name", "some-name"}))
		})

		It("replicates the tile", func() {
			argParser.ParseReturns(replicator.ApplicationConfig{Path: "/some/tile/path",
				Output: "/some/tile/output/path",
				Name:   "some-name"}, nil)
			err := app.Run([]string{"--path", "/some/tile/path", "--output", "/some/tile/output/path", "--name", "some-name"})
			Expect(err).NotTo(HaveOccurred())

			Expect(tileReplicator.ReplicateCallCount()).To(Equal(1))

			config := tileReplicator.ReplicateArgsForCall(0)
			Expect(config).To(Equal(replicator.ApplicationConfig{Path: "/some/tile/path", Output: "/some/tile/output/path", Name: "some-name"}))
		})
	})

	Context("when an error occurs", func() {
		Context("when the args cannot be parsed", func() {
			It("returns an error", func() {
				argParser.ParseReturns(replicator.ApplicationConfig{}, errors.New("a parse error occurred"))
				err := app.Run([]string{"does not matter"})
				Expect(err).To(MatchError("a parse error occurred"))
			})
		})

		Context("when the tile cannot be replicated", func() {
			It("returns an error", func() {
				tileReplicator.ReplicateReturns(errors.New("a replication error occurred"))
				err := app.Run([]string{"does not matter"})
				Expect(err).To(MatchError("a replication error occurred"))
			})
		})
	})
})

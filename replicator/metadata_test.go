package replicator_test

import (
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	"github.com/pivotal-cf/replicator/replicator"
)

var _ = Describe("metadata", func() {
	var (
		metadata replicator.Metadata
	)

	BeforeEach(func() {
		metadata = replicator.Metadata{
			FormTypes: []*replicator.FormType{
				{
					PropertyInputs: []replicator.PropertyInput{
						{Reference: ".replace_me_reference.peanut_butter"},
						{Reference: ".dont_replace_me_reference.almond_butter"},
					},
				},
			},
			JobTypes: []*replicator.JobType{
				{
					Name: "replace-me-job",
				},
				{
					Name: "dont-replace-me-job",
				},
			},
		}
	})

	Describe("RenameJob", func() {
		It("renames the job", func() {
			err := metadata.RenameJob("replace-me-job", "replaced-job")
			Expect(err).NotTo(HaveOccurred())

			Expect(metadata.JobTypes[0].Name).To(Equal("replaced-job"))
			Expect(metadata.JobTypes[1].Name).To(Equal("dont-replace-me-job"))
		})

		It("returns an error when job doesn't exist", func() {
			err := metadata.RenameJob("where-are-you-job", "replaced-job")
			Expect(err).To(MatchError(`failed to find "where-are-you-job" job`))
		})
	})

	Describe("RenameFormTypeRef", func() {
		It("renames the form type reference", func() {
			err := metadata.RenameFormTypeRef(".replace_me_reference.peanut_butter", ".replaced_reference.peanut_butter")
			Expect(err).NotTo(HaveOccurred())

			Expect(metadata.FormTypes[0].PropertyInputs[0].Reference).To(Equal(".replaced_reference.peanut_butter"))
			Expect(metadata.FormTypes[0].PropertyInputs[1].Reference).To(Equal(".dont_replace_me_reference.almond_butter"))
		})

		It("returns an error when form type ref does not exist", func() {
			err := metadata.RenameFormTypeRef(".where-are-you-reference.peanut_butter", ".replaced_reference.peanut_butter")
			Expect(err).To(MatchError(`failed to find ".where-are-you-reference.peanut_butter" form type reference`))
		})
	})
})

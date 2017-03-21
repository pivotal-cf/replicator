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
		It("renames the job and returns true", func() {
			result := metadata.RenameJob("replace-me-job", "replaced-job")
			Expect(result).To(BeTrue())

			Expect(metadata.JobTypes[0].Name).To(Equal("replaced-job"))
			Expect(metadata.JobTypes[1].Name).To(Equal("dont-replace-me-job"))
		})

		It("returns false when job doesn't exist", func() {
			result := metadata.RenameJob("where-are-you-job", "replaced-job")
			Expect(result).To(BeFalse())
		})
	})

	Describe("RenameFormTypeRef", func() {
		It("renames the form type reference and returns true", func() {
			result := metadata.RenameFormTypeRef(".replace_me_reference.peanut_butter", ".replaced_reference.peanut_butter")
			Expect(result).To(BeTrue())

			Expect(metadata.FormTypes[0].PropertyInputs[0].Reference).To(Equal(".replaced_reference.peanut_butter"))
			Expect(metadata.FormTypes[0].PropertyInputs[1].Reference).To(Equal(".dont_replace_me_reference.almond_butter"))
		})
	})
})

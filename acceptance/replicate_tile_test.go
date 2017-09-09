package acceptance

import (
	"os"
	"os/exec"
	"path/filepath"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

var _ = Describe("replicator", func() {
	Context("when replicating the isolation segment tile", func() {
		It("writes a file without erroring", func() {
			pathToTile := filepath.Join("fixtures", "ist.pivotal")
			pathToOutputTile := filepath.Join(os.TempDir(), "ist-duplicated.pivotal")

			command := exec.Command(pathToMain,
				"--path", pathToTile,
				"--output", pathToOutputTile,
				"--name", "blue")

			session, err := gexec.Start(command, GinkgoWriter, GinkgoWriter)
			Eventually(session).Should(gexec.Exit(0))
			Expect(err).NotTo(HaveOccurred())

			Expect(pathToOutputTile).To(BeAnExistingFile())
		})
	})
	Context("when replicating the windows runtime tile", func() {
		It("writes a file without erroring", func() {
			pathToTile := filepath.Join("fixtures", "wrt.pivotal")
			pathToOutputTile := filepath.Join(os.TempDir(), "wrt-duplicated.pivotal")

			command := exec.Command(pathToMain,
				"--path", pathToTile,
				"--output", pathToOutputTile,
				"--name", "indigo")

			session, err := gexec.Start(command, GinkgoWriter, GinkgoWriter)
			Eventually(session).Should(gexec.Exit(0))
			Expect(err).NotTo(HaveOccurred())

			Expect(pathToOutputTile).To(BeAnExistingFile())
		})
	})
})

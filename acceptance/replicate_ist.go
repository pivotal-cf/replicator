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
	It("duplicates the isolation segment tile", func() {
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

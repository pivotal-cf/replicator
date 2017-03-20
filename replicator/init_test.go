package replicator

import (
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	"testing"
)

var (
	pathToMain string
)

func TestReplicator(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "replicator")
}

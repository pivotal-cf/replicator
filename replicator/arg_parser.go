package replicator

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strings"
)

type ArgParser struct{}

func NewArgParser() ArgParser {
	return ArgParser{}
}

func (ArgParser) Parse(args []string) (ApplicationConfig, error) {
	cfg := ApplicationConfig{}

	flagSet := flag.NewFlagSet("replicator", flag.ExitOnError)
	flagSet.StringVar(&cfg.Name, "name", "", "unique identifier for the duplicated tile. The only permitted special characters are hyphens, underscores, and spaces.")
	flagSet.StringVar(&cfg.Path, "path", "", "path to source tile")
	flagSet.StringVar(&cfg.Output, "output", "", "desired path for the duplicated tile")
	flagSet.Parse(args)

	var errMsgs []string

	if cfg.Name == "" {
		errMsgs = append(errMsgs, "--name is a required argument")
	}

	matchLegalCharacters, err := regexp.Match("^[a-zA-Z0-9-_ ]*$", []byte(cfg.Name))
	if err != nil {
		errMsgs = append(errMsgs, fmt.Sprintf("error parsing --name flag: %s", err))
	}

	if !matchLegalCharacters {
		errMsgs = append(errMsgs, fmt.Sprintf("Invalid special characters in name: %s", cfg.Name))
	}

	if cfg.Path == "" {
		errMsgs = append(errMsgs, "--path is a required argument")
	} else {
		fi, err := os.Stat(cfg.Path)
		if err != nil {
			return cfg, err
		}

		if !fi.Mode().IsRegular() {
			return cfg, fmt.Errorf("%s is not a regular file", cfg.Path)
		}
	}

	if cfg.Output == "" {
		errMsgs = append(errMsgs, "--output is a required argument")
	}

	if len(errMsgs) != 0 {
		return cfg, errors.New(strings.Join(errMsgs, ", "))
	}

	return cfg, nil
}

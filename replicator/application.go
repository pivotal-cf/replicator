package replicator

type Application struct {
	argParser      argParser
	tileReplicator tileReplicator
}

type ApplicationConfig struct {
	Name   string
	Path   string
	Output string
}

//go:generate counterfeiter -o ./fakes/arg_parser.go --fake-name ArgParser . argParser
type argParser interface {
	Parse([]string) (ApplicationConfig, error)
}

//go:generate counterfeiter -o ./fakes/tile_replicator.go --fake-name TileReplicator . tileReplicator
type tileReplicator interface {
	Replicate(ApplicationConfig) error
}

func NewApplication(argParser argParser, tileReplicator tileReplicator) Application {
	return Application{
		argParser:      argParser,
		tileReplicator: tileReplicator,
	}
}

func (r Application) Run(args []string) error {
	config, err := r.argParser.Parse(args)
	if err != nil {
		panic(err)
	}

	err = r.tileReplicator.Replicate(config)
	if err != nil {
		panic(err)
	}

	// TODO unzip .pivotal to a temp dir (config.Path)

	// TODO modify metadata/p-isolation-segment.yml (config.Name)

	// TODO zip .pivotal to the destination (config.Output)
	return nil
}

// func (u CFUnzipper) Extract(releaseName string) (string, error) {
// 	defer u.zipReader.Close()

// 	releaseTarballRegex, err := regexp.Compile(fmt.Sprintf("%s-[\\d]+.*.tgz", releaseName))
// 	if err != nil {
// 		panic(err)
// 	}

// 	releaseTarball, err := ioutil.TempFile("", "")
// 	if err != nil {
// 		return "", err // no error test
// 	}
// 	defer releaseTarball.Close()

// 	for _, file := range u.zipReader.File {
// 		if releaseTarballRegex.MatchString(file.Name) {
// 			cf, err := file.Open()
// 			if err != nil {
// 				return "", err // no error test
// 			}

// 			_, err = io.Copy(releaseTarball, cf)
// 			if err != nil {
// 				return "", err // no error test
// 			}

// 			return releaseTarball.Name(), nil
// 		}
// 	}

// 	return "", fmt.Errorf("no release %q was found in provided .pivotal", releaseName)
// }

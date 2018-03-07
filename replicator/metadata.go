package replicator

type Metadata struct {
	Name                     string
	Releases                 []interface{}
	StemcellCriteria         interface{} `yaml:"stemcell_criteria"`
	Description              string
	FormTypes                []*FormType `yaml:"form_types"`
	IconImage                string      `yaml:"icon_image"`
	InstallTimeVerifiers     interface{} `yaml:"install_time_verifiers"`
	JobTypes                 []*JobType  `yaml:"job_types"`
	Label                    string
	MetadataVersion          string        `yaml:"metadata_version"`
	MinimumVersionForUpgrade string        `yaml:"minimum_version_for_upgrade"`
	PostDeployErrands        []interface{} `yaml:"post_deploy_errands"`
	ProductVersion           string        `yaml:"product_version"`
	PropertyBlueprints       []interface{} `yaml:"property_blueprints"`
	ProvidesProductVersions  []interface{} `yaml:"provides_product_versions"`
	Rank                     int
	RequiresProductVersions  []interface{} `yaml:"requires_product_versions"`
	Serial                   bool
	Variables                []interface{} `yaml:",omitempty"`
}

type FormType struct {
	Description    string
	Label          string
	Name           string
	PropertyInputs []*PropertyInput `yaml:"property_inputs"`
}

type PropertyInput struct {
	Description            string `yaml:"description,omitempty"`
	Label                  string
	Placeholder            string `yaml:"placeholder,omitempty"`
	Reference              string
	SelectorPropertyInputs []*SelectorPropertyInput `yaml:"selector_property_inputs,omitempty"`
	PropertyInputs         []*PropertyInput         `yaml:"property_inputs,omitempty"`
}

type SelectorPropertyInput struct {
	Label          string
	Reference      string
	PropertyInputs []*PropertyInput `yaml:"property_inputs,omitempty"`
}

type JobType struct {
	Description         string      `yaml:",omitempty"`
	DynamicIP           int         `yaml:"dynamic_ip"`
	InstanceDefinition  interface{} `yaml:"instance_definition"`
	Serial              bool        `yaml:",omitempty"`
	Label               string
	Manifest            interface{} `yaml:",omitempty"`
	MaxInFlight         interface{} `yaml:"max_in_flight"`
	StaticIP            int         `yaml:"static_ip"`
	Name                string
	PropertyBlueprints  []interface{} `yaml:"property_blueprints"`
	ResourceDefinitions []interface{} `yaml:"resource_definitions"`
	ResourceLabel       string        `yaml:"resource_label"`
	SingleAzOnly        bool          `yaml:"single_az_only"`
	Templates           []interface{}
	Errand              bool `yaml:",omitempty"`
}

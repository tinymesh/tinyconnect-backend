use Mix.Config

config :tinyconnect,
  remote: "http://http.stage.highlands.tiny-mesh.com/v2",
  networks: %{
    "D" => %{
      :token => {
        "3719e7f7beaae3e8fd7bae1e16e1812b145ed903c258157f4b9702f9ff832123",
        "AffcDTn57Ml+orgpOf4Nq59Kjs11PJEdTUfBhud2sHP0dJfBRvQn5KM1cSB6H3XlfCnu3EvX6FWQ48iZoUYRlg=="
      }
    }
  }

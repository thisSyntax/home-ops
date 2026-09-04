terraform {
    required_version = ">= 1.5.0"

    required_providers {
        null = {
            source = "hashicorp/null"
            version = "~> 3.3"
        }
        external = {
            source = "hashicorp/external"
            version = "~> 2.4"
        }
    }
}
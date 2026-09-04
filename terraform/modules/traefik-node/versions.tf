terraform {
    required_providers {
        null = {
            source = "hashicorp/null"
            version = "~> 3.3"
        }
        docker = {
            source  = "kreuzwerker/docker"
            version = "~> 3.0"
        }
    }
}

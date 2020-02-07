pipeline {
    agent any
    stages {
        stage('Build for Debian Wheezy / ARM') {
            steps {
                sh "sudo docker run --rm -t -e BRANCH=${env.BRANCH_NAME} eblocker-dns-arm:wheezy"
            }
        }
        stage('Build for Debian Jessie / ARM') {
            steps {
                sh "sudo docker run --rm -t -e BRANCH=${env.BRANCH_NAME} eblocker-dns-arm:jessie"
            }
        }
        stage('Build for Debian Stretch / ARM') {
            steps {
                sh "sudo docker run --rm -t -e BRANCH=${env.BRANCH_NAME} eblocker-dns-arm:stretch"
            }
        }
        stage('Build for Debian Stretch / AMD64') {
            steps {
                sh "sudo docker run --rm -t -e BRANCH=${env.BRANCH_NAME} eblocker-dns-amd64:stretch"
            }
        }
    }
}

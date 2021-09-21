# deploy
GH Action for Splunk instalation inside GH Workflow 


example of usage: 

      - uses: splunk-actions/deploy@main
        id: splunk
        name: "Spinning env"
        with:
          package-name: 'splunk-add-on-package-name.tgz'

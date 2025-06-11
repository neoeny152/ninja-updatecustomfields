# ninja-updatecustomfields

1. Create a text custom field 
2. Create your NinjaOne client ID and secret  
3. Create a CSV with this format:

    ```
    device name,textcustomfieldname
    device1,whatyouwantthefieldupdatedwith
    ```
4. The script will pull a list of all of your devices and use that to match the items in your list with a known node ID, then it will update the custom field in question. 


The idea for this came from https://ninjarmm.zendesk.com/hc/en-us/community/posts/13134934780045-Script-Share-Import-Data-from-Spreadsheet-into-Custom-Fields-API
## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: list of exceptionally stupid templates.

# A list of templates that we 'boycott' because they render
# improperly no matter how we add a {{Dead link}} tag.
# This happens because the parameter expects a bare URL,
# and (internally) the template wraps that URL in a bracket
# link.  This table maps template names to list of fields.
# The empty list represents /any field/.
BOYCOTT_TEMPLATES = {
  'infobox writer' => ['website'],
  'infobox ncaa football school' => ['websiteurl'],
  'infobox officeholder' => ['source'],
  # Begin redirects to {{infobox officeholder}}
  'infobox am' => ['source'],
  'infobox ambassador' => ['source'],
  'infobox canadian mp' => ['source'],
  'infobox canadian senator' => ['source'],
  'infobox candidate' => ['source'],
  'infobox chancellor' => ['source'],
  'infobox congressional candidate' => ['source'],
  'infobox congressman' => ['source'],
  'infobox defense minister' => ['source'],
  'infobox deputy first minister' => ['source'],
  'infobox deputy prime minister' => ['source'],
  'infobox dodge' => ['source'],
  'infobox eritrea cabinet official' => ['source'],
  'infobox first lady' => ['source'],
  'infobox first minister' => ['source'],
  'infobox governor' => ['source'],
  'infobox governor-elect' => ['source'],
  'infobox governor general' => ['source'],
  'infobox governor-general' => ['source'],
  'infobox indian politician' => ['source'],
  'infobox judge' => ['source'],
  'infobox lt governor' => ['source'],
  'infobox mayor' => ['source'],
  'infobox mep' => ['source'],
  'infobox minister' => ['source'],
  'infobox mla' => ['source'],
  'infobox mp' => ['source'],
  'infobox msp' => ['source'],
  'infobox pm' => ['source'],
  'infobox politician' => ['source'],
  'infobox politician (general)' => ['source'],
  'infobox premier' => ['source'],
  'infobox president' => ['source'],
  'infobox president-elect' => ['source'],
  'infobox prime minister' => ['source'],
  'infobox prime minister-elect' => ['source'],
  'infobox representative-elect' => ['source'],
  'infobox scc chief justice' => ['source'],
  'infobox scc puisne justice' => ['source'],
  'infobox secretary-general' => ['source'],
  'infobox senator' => ['source'],
  'infobox senator-elect' => ['source'],
  'infobox speaker' => ['source'],
  'infobox state representative' => ['source'],
  'infobox state sc associate justice' => ['source'],
  'infobox state sc justice' => ['source'],
  'infobox state senator' => ['source'],
  'infobox us ambassador' => ['source'],
  'infobox us associate justice' => ['source'],
  'infobox us cabinet official' => ['source'],
  'infobox us chief justice' => ['source'],
  'infobox us territorial governor' => ['source'],
  'infobox vice president' => ['source'],
  # end redirects to {{infobox officeholder}}
}

# These templates are okay so long as we put
# {{Dead link}} after the template.
TAG_AFTER_TEMPLATES = ['url', 'official website']



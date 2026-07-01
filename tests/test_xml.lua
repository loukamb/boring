return function(t)
    local xml = require("shared.xml")

    t.test("parses quoted greater-than signs inside attributes", function()
        local seen
        xml.parse('<entry summary="x > 0" other="ok"/>', {
            start_element = function(tag, attrs)
                seen = { tag = tag, summary = attrs.summary, other = attrs.other }
            end,
        })

        t.eq(seen.tag, "entry")
        t.eq(seen.summary, "x > 0")
        t.eq(seen.other, "ok")
    end)

    t.test("decodes XML entities in attributes and text", function()
        local attr
        local text
        xml.parse('<entry value="&lt;&gt;&amp;&quot;&apos;">a &amp; b</entry>', {
            start_element = function(_, attrs)
                attr = attrs.value
            end,
            text = function(value)
                text = value
            end,
        })

        t.eq(attr, "<>&\"'")
        t.eq(text, "a & b")
    end)

    t.test("parses comments, cdata, and self-closing tags", function()
        local tags = {}
        local text = {}
        xml.parse('<root><!--skip--><child/><data><![CDATA[x < y]]></data></root>', {
            start_element = function(tag)
                table.insert(tags, tag)
            end,
            text = function(value)
                table.insert(text, value)
            end,
        })

        t.eq(table.concat(tags, ","), "root,child,data")
        t.eq(table.concat(text, ""), "x < y")
    end)
end

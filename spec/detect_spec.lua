local detect = require("sops.detect")

describe("detection", function()
    it(
        "recognises an encrypted yaml file",
        function()
            assert.is_true(detect.is_encrypted({
                "password: ENC[AES256_GCM,data:Tr7o,iv:1yA=,tag:QGpA==,type:str]",
                "sops:",
                "    version: 3.13.3",
            }))
        end
    )

    it(
        "recognises an encrypted json file",
        function()
            assert.is_true(detect.is_encrypted({
                "{",
                '	"password": "ENC[AES256_GCM,data:Tr7o,iv:1yA=,tag:QGpA==,type:str]",',
                '	"sops": {',
                '		"version": "3.13.3"',
                "	}",
                "}",
            }))
        end
    )

    it(
        "recognises an encrypted dotenv file",
        function()
            assert.is_true(detect.is_encrypted({
                "PASSWORD=ENC[AES256_GCM,data:Tr7o,iv:1yA=,tag:QGpA==,type:str]",
                "sops_version=3.13.3",
            }))
        end
    )

    it(
        "recognises an encrypted ini file",
        function()
            assert.is_true(detect.is_encrypted({
                "[secrets]",
                "password = ENC[AES256_GCM,data:Tr7o,iv:1yA=,tag:QGpA==,type:str]",
                "[sops]",
                "version = 3.13.3",
            }))
        end
    )

    it(
        "leaves a plain file alone",
        function() assert.is_false(detect.is_encrypted({ "password: hunter2", "other: value" })) end
    )

    it("needs more than a file that talks about sops", function()
        assert.is_false(detect.is_encrypted({ "sops:", "    version: 3.13.3" }))
        assert.is_false(detect.is_encrypted({ "note: we use sops for this" }))
    end)

    it(
        "needs more than an encrypted looking value",
        function()
            assert.is_false(detect.is_encrypted({ "password: ENC[AES256_GCM,data:Tr7o,type:str]" }))
        end
    )

    it("handles an empty buffer", function() assert.is_false(detect.is_encrypted({})) end)
end)

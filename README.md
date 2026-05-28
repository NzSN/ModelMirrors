# Model Mirrors

# Introduction
ModelMirrors is a system that used to gurantee that implementation of 
a model follow all rules introduce by the model.

One of goals is to languages independent. For this purpose, ModelMirrors is design
to be run in a seperate process (called as 'Mirror Process'). Client Process (a
process who expect to verify it's implementation by send request Mirror Process).
is communicate with Mirror Process via IPC.

ModelMirrors leverage the power of TLA+ and Apalache to do trace replay for an 
implementaion of a model.

# Design

## Protocol
Language independent is a goal fo Model Mirrors. Hence there should be a common knowleadge
between implementation of client process and mirror process, which is protocol.

The protocol should allow following workflow:
1. client request to mirror process to register spec with url or path to the tla+ spec file.
   In this steps, client should able to config how traces is generated, for example, 
   number of trace and length of trace, etc.
2. run apalache onto the tla+ spec file to make sure it's sound, 
   report success if the spec is pass the check of apalache otherwise 
   report failure.
3. mirror process send back initial states to client.
4. mirror send steps sequencely, begin from first step.
5. client reply stats after step run to mirror process.
6. mirror process reply for correctness of states, mirror do a comparision 
   between client's actual state and ITF trace's expected state, return success
   if they are equal otherwise failure.
7. if reply state not match with state in itf trace then report failure
   otherwise next step.
8. repeat 4-7 steps until there has no next step.
9. report that implementation is correct with respect to the 
   given itf trace.

